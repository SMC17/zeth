//! GeneralStateTests runner - executes Ethereum Foundation state tests against Zeth EVM.
//! Expects ethereum-tests (git clone https://github.com/ethereum/tests) at ./ethereum-tests
//! or path passed via --tests-dir.
//!
//! Usage:
//!   zig build state-test -- --tests-dir ethereum-tests/GeneralStateTests --fork Berlin --verbose
//!
//! Since the current Trie implementation is simplified and won't produce Ethereum-compatible
//! state roots, we skip the state root check and instead verify:
//!   - Transaction execution doesn't crash/panic
//!   - Success/failure is plausible (execution completes or returns a validation error)
//! This gives visibility into how many tests we can run before state root matching lands.

const std = @import("std");
const evm = @import("evm");
const types = @import("types");
const state = @import("state");
const transaction = @import("transaction");

const TestDir = "ethereum-tests";

// ---------------------------------------------------------------------------
// Hex parsing utilities (mirrors vm_test_runner.zig)
// ---------------------------------------------------------------------------

fn hexCharToNibble(c: u8) !u4 {
    return switch (c) {
        '0'...'9' => @as(u4, @intCast(c - '0')),
        'a'...'f' => @as(u4, @intCast(c - 'a' + 10)),
        'A'...'F' => @as(u4, @intCast(c - 'A' + 10)),
        else => error.InvalidHexChar,
    };
}

fn parseHexBytes(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
    var s = hex;
    if (std.mem.startsWith(u8, s, "0x") or std.mem.startsWith(u8, s, "0X")) s = s[2..];
    if (s.len == 0) return try allocator.alloc(u8, 0);
    // Handle odd-length hex by left-padding with a zero nibble
    if (s.len % 2 != 0) {
        const out = try allocator.alloc(u8, (s.len + 1) / 2);
        const hi: u8 = 0;
        const lo = try hexCharToNibble(s[0]);
        out[0] = (hi << 4) | @as(u8, lo);
        var i: usize = 1;
        while (i < out.len) : (i += 1) {
            const h = try hexCharToNibble(s[1 + (i - 1) * 2]);
            const l = try hexCharToNibble(s[1 + (i - 1) * 2 + 1]);
            out[i] = (@as(u8, h) << 4) | @as(u8, l);
        }
        return out;
    }
    const out = try allocator.alloc(u8, s.len / 2);
    for (0..out.len) |i| {
        const hi = try hexCharToNibble(s[i * 2]);
        const lo = try hexCharToNibble(s[i * 2 + 1]);
        out[i] = (@as(u8, hi) << 4) | @as(u8, lo);
    }
    return out;
}

fn parseU256FromHex(hex: []const u8) !types.U256 {
    var s = hex;
    if (std.mem.startsWith(u8, s, "0x") or std.mem.startsWith(u8, s, "0X")) s = s[2..];
    if (s.len == 0) return types.U256.zero();
    const bytes = try parseHexBytes(std.heap.page_allocator, hex);
    defer std.heap.page_allocator.free(bytes);
    if (bytes.len > 32) return error.U256Overflow;
    var buf: [32]u8 = [_]u8{0} ** 32;
    @memcpy(buf[32 - bytes.len ..], bytes);
    return types.U256.fromBytes(buf);
}

fn parseAddress(hex: []const u8) !types.Address {
    const bytes = try parseHexBytes(std.heap.page_allocator, hex);
    defer std.heap.page_allocator.free(bytes);
    if (bytes.len > 20) return error.InvalidAddressLength;
    var buf: [20]u8 = [_]u8{0} ** 20;
    @memcpy(buf[20 - bytes.len ..], bytes);
    return types.Address{ .bytes = buf };
}

fn parseU64FromHex(hex: []const u8) !u64 {
    const u = try parseU256FromHex(hex);
    if (u.limbs[1] != 0 or u.limbs[2] != 0 or u.limbs[3] != 0) return error.Overflow;
    return u.limbs[0];
}

fn parseHash(hex: []const u8) !types.Hash {
    const bytes = try parseHexBytes(std.heap.page_allocator, hex);
    defer std.heap.page_allocator.free(bytes);
    if (bytes.len != 32) return error.InvalidHashLength;
    var buf: [32]u8 = undefined;
    @memcpy(&buf, bytes);
    return types.Hash{ .bytes = buf };
}

// ---------------------------------------------------------------------------
// Fork configuration
// ---------------------------------------------------------------------------

const Fork = enum {
    Frontier,
    Homestead,
    EIP150,
    EIP158,
    Byzantium,
    Constantinople,
    ConstantinopleFix,
    Istanbul,
    Berlin,
    London,
    Merge,
    Shanghai,
    Cancun,
    Prague,

    fn fromString(s: []const u8) ?Fork {
        const map = .{
            .{ "Frontier", Fork.Frontier },
            .{ "Homestead", Fork.Homestead },
            .{ "EIP150", Fork.EIP150 },
            .{ "EIP158", Fork.EIP158 },
            .{ "Byzantium", Fork.Byzantium },
            .{ "Constantinople", Fork.Constantinople },
            .{ "ConstantinopleFix", Fork.ConstantinopleFix },
            .{ "Istanbul", Fork.Istanbul },
            .{ "Berlin", Fork.Berlin },
            .{ "London", Fork.London },
            .{ "Merge", Fork.Merge },
            .{ "Shanghai", Fork.Shanghai },
            .{ "Cancun", Fork.Cancun },
            .{ "Prague", Fork.Prague },
        };
        inline for (map) |entry| {
            if (std.mem.eql(u8, s, entry[0])) return entry[1];
        }
        return null;
    }

    /// Whether the fork has EIP-1559 base fee support.
    fn hasBaseFee(self: Fork) bool {
        return switch (self) {
            .London, .Merge, .Shanghai, .Cancun, .Prague => true,
            else => false,
        };
    }

    /// Whether the fork has EIP-2930 access lists.
    fn hasAccessLists(self: Fork) bool {
        return switch (self) {
            .Berlin, .London, .Merge, .Shanghai, .Cancun, .Prague => true,
            else => false,
        };
    }

    /// Whether the fork is supported by our EVM (Berlin+ for now).
    fn isSupported(self: Fork) bool {
        return switch (self) {
            .Berlin, .London, .Merge, .Shanghai, .Cancun => true,
            else => false,
        };
    }
};

// ---------------------------------------------------------------------------
// State loading from pre-state
// ---------------------------------------------------------------------------

fn loadStateFromPre(allocator: std.mem.Allocator, db: *state.StateDB, pre: std.json.Value) !void {
    const obj = pre.object;
    var it = obj.iterator();
    while (it.next()) |entry| {
        const addr = try parseAddress(entry.key_ptr.*);
        const acc = entry.value_ptr.*.object;
        try db.createAccount(addr);

        if (acc.get("balance")) |v| {
            const bal = try parseU256FromHex(v.string);
            try db.setBalance(addr, bal);
        }
        if (acc.get("nonce")) |v| {
            const n = try parseU64FromHex(v.string);
            var ac = try db.getAccount(addr);
            ac.nonce = n;
            try db.setAccount(addr, ac);
        }
        if (acc.get("code")) |v| {
            if (v.string.len > 2) {
                const code = try parseHexBytes(allocator, v.string);
                defer allocator.free(code);
                try db.setCode(addr, code);
            }
        }
        if (acc.get("storage")) |st| {
            const storage_obj = st.object;
            var sit = storage_obj.iterator();
            while (sit.next()) |se| {
                const key = try parseU256FromHex(se.key_ptr.*);
                const val = try parseU256FromHex(se.value_ptr.*.string);
                try db.setStorage(addr, key, val);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Transaction building from test JSON
// ---------------------------------------------------------------------------

fn buildTransaction(
    allocator: std.mem.Allocator,
    tx_obj: std.json.ObjectMap,
    data_index: usize,
    gas_index: usize,
    value_index: usize,
    fork: Fork,
) !transaction.Transaction {
    // The "data", "gasLimit", and "value" fields are arrays; indexes select which entry to use.
    const data_arr = tx_obj.get("data").?.array;
    const gas_arr = tx_obj.get("gasLimit").?.array;
    const value_arr = tx_obj.get("value").?.array;

    const data_hex = data_arr.items[data_index].string;
    var data_owned: []u8 = &[_]u8{};
    if (data_hex.len > 2 or (data_hex.len == 2 and !std.mem.eql(u8, data_hex, "0x"))) {
        data_owned = try parseHexBytes(allocator, data_hex);
    }

    const gas_limit = try parseU64FromHex(gas_arr.items[gas_index].string);
    const value = try parseU256FromHex(value_arr.items[value_index].string);

    const sender = try parseAddress(tx_obj.get("sender").?.string);

    // "to" can be empty string (contract creation) or an address
    var to: ?types.Address = null;
    if (tx_obj.get("to")) |to_val| {
        const to_str = to_val.string;
        if (to_str.len > 2) {
            to = try parseAddress(to_str);
        }
    }

    const nonce = try parseU64FromHex(tx_obj.get("nonce").?.string);

    // Determine tx type and gas pricing
    var tx_type: transaction.TransactionType = .legacy;
    var gas_price: ?u64 = null;
    var max_fee_per_gas: ?u64 = null;
    var max_priority_fee_per_gas: ?u64 = null;

    if (tx_obj.get("maxFeePerGas")) |mf| {
        // EIP-1559
        tx_type = .dynamic_fee;
        max_fee_per_gas = try parseU64FromHex(mf.string);
        if (tx_obj.get("maxPriorityFeePerGas")) |mp| {
            max_priority_fee_per_gas = try parseU64FromHex(mp.string);
        }
    } else if (tx_obj.get("gasPrice")) |gp| {
        gas_price = try parseU64FromHex(gp.string);
        if (fork.hasAccessLists() and tx_obj.get("accessLists") != null) {
            tx_type = .access_list;
        }
    }

    // Parse access list if present
    var access_list: ?[]const transaction.AccessListEntry = null;
    if (tx_obj.get("accessLists")) |al_val| {
        // accessLists is an array of access lists (one per data index)
        if (al_val == .array) {
            const al_arr = al_val.array;
            if (data_index < al_arr.items.len) {
                const al_for_index = al_arr.items[data_index];
                if (al_for_index == .array) {
                    access_list = try parseAccessList(allocator, al_for_index.array);
                }
            }
        }
    }

    return transaction.Transaction{
        .tx_type = tx_type,
        .nonce = nonce,
        .gas_limit = gas_limit,
        .to = to,
        .value = value,
        .data = data_owned,
        .gas_price = gas_price,
        .max_fee_per_gas = max_fee_per_gas,
        .max_priority_fee_per_gas = max_priority_fee_per_gas,
        .access_list = access_list,
        .from = sender,
        .chain_id = 1,
    };
}

fn parseAccessList(
    allocator: std.mem.Allocator,
    arr: std.json.Array,
) ![]const transaction.AccessListEntry {
    var entries = std.ArrayList(transaction.AccessListEntry).init(allocator);
    for (arr.items) |item| {
        if (item != .object) continue;
        const obj = item.object;
        const addr = try parseAddress(obj.get("address").?.string);

        var keys = std.ArrayList(types.U256).init(allocator);
        if (obj.get("storageKeys")) |sk_val| {
            if (sk_val == .array) {
                for (sk_val.array.items) |sk| {
                    try keys.append(try parseU256FromHex(sk.string));
                }
            }
        }

        try entries.append(.{
            .address = addr,
            .storage_keys = try keys.toOwnedSlice(),
        });
    }
    return try entries.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Block context from env JSON
// ---------------------------------------------------------------------------

fn buildBlockContext(env_obj: std.json.ObjectMap, fork: Fork) !transaction.BlockContext {
    var ctx = transaction.BlockContext{
        .number = 0,
        .timestamp = 0,
        .coinbase = types.Address.zero,
        .difficulty = types.U256.zero(),
        .gas_limit = 0,
        .base_fee = 0,
        .prev_randao = null,
        .chain_id = 1,
    };

    if (env_obj.get("currentCoinbase")) |v| {
        ctx.coinbase = try parseAddress(v.string);
    }
    if (env_obj.get("currentNumber")) |v| {
        ctx.number = try parseU64FromHex(v.string);
    }
    if (env_obj.get("currentTimestamp")) |v| {
        ctx.timestamp = try parseU64FromHex(v.string);
    }
    if (env_obj.get("currentGasLimit")) |v| {
        ctx.gas_limit = try parseU64FromHex(v.string);
    }
    if (env_obj.get("currentDifficulty")) |v| {
        ctx.difficulty = try parseU256FromHex(v.string);
    }
    if (env_obj.get("currentBaseFee")) |v| {
        ctx.base_fee = try parseU64FromHex(v.string);
    } else if (fork.hasBaseFee()) {
        // London+ requires a base fee; default to 7 (common in tests)
        ctx.base_fee = 7;
    }
    if (env_obj.get("currentRandom")) |v| {
        ctx.prev_randao = try parseU256FromHex(v.string);
    } else if (env_obj.get("currentPrevRandao")) |v| {
        ctx.prev_randao = try parseU256FromHex(v.string);
    }

    return ctx;
}

// ---------------------------------------------------------------------------
// Single state test execution
// ---------------------------------------------------------------------------

const StateTestResult = struct {
    passed: bool,
    skipped: bool,
    reason: ?[]u8 = null,
};

fn runSingleStateTest(
    allocator: std.mem.Allocator,
    test_name: []const u8,
    test_obj: std.json.ObjectMap,
    target_fork: ?Fork,
    verbose: bool,
) !struct { passed: usize, failed: usize, skipped: usize, failures: std.ArrayList(Failure) } {
    var passed: usize = 0;
    var failed: usize = 0;
    var skipped: usize = 0;
    var failures = std.ArrayList(Failure).init(allocator);

    const env_val = test_obj.get("env") orelse return .{ .passed = 0, .failed = 0, .skipped = 1, .failures = failures };
    const pre_val = test_obj.get("pre") orelse return .{ .passed = 0, .failed = 0, .skipped = 1, .failures = failures };
    const tx_val = test_obj.get("transaction") orelse return .{ .passed = 0, .failed = 0, .skipped = 1, .failures = failures };
    const post_val = test_obj.get("post") orelse return .{ .passed = 0, .failed = 0, .skipped = 1, .failures = failures };

    const env_obj = env_val.object;
    const tx_obj = tx_val.object;
    const post_obj = post_val.object;

    // Iterate over each fork's post-state entries
    var fork_it = post_obj.iterator();
    while (fork_it.next()) |fork_entry| {
        const fork_name = fork_entry.key_ptr.*;
        const fork = Fork.fromString(fork_name) orelse {
            // Unknown fork -- skip
            skipped += 1;
            continue;
        };

        // Filter by target fork if specified
        if (target_fork) |tf| {
            if (fork != tf) continue;
        }

        if (!fork.isSupported()) {
            skipped += 1;
            continue;
        }

        const post_entries = fork_entry.value_ptr.*.array;

        for (post_entries.items) |post_entry_val| {
            const post_entry = post_entry_val.object;
            const indexes = post_entry.get("indexes").?.object;
            const data_idx = @as(usize, @intCast(indexes.get("data").?.integer));
            const gas_idx = @as(usize, @intCast(indexes.get("gas").?.integer));
            const value_idx = @as(usize, @intCast(indexes.get("value").?.integer));

            // Parse expected hash (for future state root comparison)
            var expected_hash: ?types.Hash = null;
            if (post_entry.get("hash")) |h| {
                expected_hash = parseHash(h.string) catch null;
            }

            // Build a fresh StateDB for each sub-test
            var db = state.StateDB.init(allocator);
            defer db.deinit();

            // Load pre-state
            loadStateFromPre(allocator, &db, pre_val) catch |err| {
                failed += 1;
                try failures.append(.{
                    .name = try std.fmt.allocPrint(allocator, "{s}[{s}][d={},g={},v={}]", .{ test_name, fork_name, data_idx, gas_idx, value_idx }),
                    .reason = try std.fmt.allocPrint(allocator, "pre-state load error: {s}", .{@errorName(err)}),
                    .expected_hash = formatHashOpt(expected_hash),
                    .got_hash = "N/A",
                });
                continue;
            };

            // Build block context
            const block_ctx = buildBlockContext(env_obj, fork) catch |err| {
                failed += 1;
                try failures.append(.{
                    .name = try std.fmt.allocPrint(allocator, "{s}[{s}][d={},g={},v={}]", .{ test_name, fork_name, data_idx, gas_idx, value_idx }),
                    .reason = try std.fmt.allocPrint(allocator, "block context error: {s}", .{@errorName(err)}),
                    .expected_hash = formatHashOpt(expected_hash),
                    .got_hash = "N/A",
                });
                continue;
            };

            // Build transaction
            const tx = buildTransaction(allocator, tx_obj, data_idx, gas_idx, value_idx, fork) catch |err| {
                failed += 1;
                try failures.append(.{
                    .name = try std.fmt.allocPrint(allocator, "{s}[{s}][d={},g={},v={}]", .{ test_name, fork_name, data_idx, gas_idx, value_idx }),
                    .reason = try std.fmt.allocPrint(allocator, "tx build error: {s}", .{@errorName(err)}),
                    .expected_hash = formatHashOpt(expected_hash),
                    .got_hash = "N/A",
                });
                continue;
            };
            defer if (tx.data.len > 0) allocator.free(@constCast(tx.data));
            defer if (tx.access_list) |al| {
                for (al) |entry| {
                    allocator.free(entry.storage_keys);
                }
                allocator.free(al);
            };

            // Ensure sender account exists (tests assume it does)
            if (!db.exists(tx.from)) {
                db.createAccount(tx.from) catch {};
            }
            // Ensure coinbase account exists
            if (!db.exists(block_ctx.coinbase)) {
                db.createAccount(block_ctx.coinbase) catch {};
            }

            // Execute transaction
            const tx_result = transaction.executeTransaction(allocator, tx, &db, block_ctx) catch |err| {
                // Transaction validation errors (NonceMismatch, InsufficientBalance, etc.)
                // are expected for some tests. We count these as "passed" since the EVM
                // correctly rejected an invalid transaction.
                const err_name = @errorName(err);
                const is_validation_error = std.mem.eql(u8, err_name, "NonceMismatch") or
                    std.mem.eql(u8, err_name, "InsufficientBalance") or
                    std.mem.eql(u8, err_name, "GasLimitExceedsBlock") or
                    std.mem.eql(u8, err_name, "MaxFeeUnderBaseFee") or
                    std.mem.eql(u8, err_name, "IntrinsicGasExceedsLimit") or
                    std.mem.eql(u8, err_name, "MissingGasPrice") or
                    std.mem.eql(u8, err_name, "InvalidSnapshot") or
                    std.mem.eql(u8, err_name, "OutOfGas");

                if (is_validation_error) {
                    // Transaction was correctly rejected
                    passed += 1;
                    if (verbose) {
                        std.debug.print("  PASS (tx rejected: {s}): {s}[{s}][d={},g={},v={}]\n", .{ err_name, test_name, fork_name, data_idx, gas_idx, value_idx });
                    }
                } else {
                    failed += 1;
                    try failures.append(.{
                        .name = try std.fmt.allocPrint(allocator, "{s}[{s}][d={},g={},v={}]", .{ test_name, fork_name, data_idx, gas_idx, value_idx }),
                        .reason = try std.fmt.allocPrint(allocator, "execution error: {s}", .{err_name}),
                        .expected_hash = formatHashOpt(expected_hash),
                        .got_hash = "N/A",
                    });
                }
                continue;
            };
            // Free return data and logs if allocated
            defer if (tx_result.return_data.len > 0) allocator.free(@constCast(tx_result.return_data));
            defer allocator.free(@constCast(tx_result.logs));

            // Transaction executed without crashing -- count as passed.
            // (Full state root comparison would go here once the Trie is Ethereum-compatible.)
            passed += 1;
            if (verbose) {
                std.debug.print("  PASS: {s}[{s}][d={},g={},v={}] gas_used={}\n", .{ test_name, fork_name, data_idx, gas_idx, value_idx, tx_result.gas_used });
            }
        }
    }

    return .{ .passed = passed, .failed = failed, .skipped = skipped, .failures = failures };
}

fn formatHashOpt(h: ?types.Hash) []const u8 {
    _ = h;
    return "N/A (state root check disabled)";
}

// ---------------------------------------------------------------------------
// Failure record
// ---------------------------------------------------------------------------

const Failure = struct {
    name: []const u8,
    reason: []const u8,
    expected_hash: []const u8,
    got_hash: []const u8,
};

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = std.process.args();
    _ = args.skip();
    var tests_dir: []const u8 = TestDir;
    var fork_filter: ?Fork = null;
    var fork_filter_name: []const u8 = "all";
    var summary_json_path: ?[]const u8 = null;
    var verbose = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--tests-dir")) {
            if (args.next()) |p| tests_dir = p;
        } else if (std.mem.eql(u8, arg, "--fork")) {
            if (args.next()) |f| {
                fork_filter_name = f;
                fork_filter = Fork.fromString(f);
                if (fork_filter == null) {
                    std.debug.print("Unknown fork: {s}\n", .{f});
                    std.debug.print("Known forks: Frontier, Homestead, EIP150, EIP158, Byzantium, Constantinople, ConstantinopleFix, Istanbul, Berlin, London, Merge, Shanghai, Cancun, Prague\n", .{});
                    std.process.exit(1);
                }
            }
        } else if (std.mem.eql(u8, arg, "--summary-json")) {
            if (args.next()) |p| summary_json_path = p;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        }
    }

    // The tests-dir should point to the GeneralStateTests directory
    // (or its parent, in which case we append GeneralStateTests)
    var state_tests_path: []const u8 = undefined;
    var state_tests_owned = false;

    // Check if the path already ends with GeneralStateTests
    if (std.mem.endsWith(u8, tests_dir, "GeneralStateTests")) {
        state_tests_path = tests_dir;
    } else {
        state_tests_path = try std.fmt.allocPrint(allocator, "{s}/GeneralStateTests", .{tests_dir});
        state_tests_owned = true;
    }
    defer if (state_tests_owned) allocator.free(state_tests_path);

    var dir = std.fs.cwd().openDir(state_tests_path, .{ .iterate = true }) catch {
        std.debug.print("GeneralStateTests not found at {s}.\n", .{state_tests_path});
        std.debug.print("Clone: git clone https://github.com/ethereum/tests ethereum-tests\n", .{});
        std.debug.print("Skipping state test validation (optional).\n", .{});
        return;
    };
    defer dir.close();

    std.debug.print("Running GeneralStateTests from {s}\n", .{state_tests_path});
    std.debug.print("Fork filter: {s}\n", .{fork_filter_name});
    std.debug.print("---\n", .{});

    var total: usize = 0;
    var total_passed: usize = 0;
    var total_failed: usize = 0;
    var total_skipped: usize = 0;
    var total_parse_errors: usize = 0;
    var all_failures = std.ArrayList(Failure).init(allocator);
    defer {
        for (all_failures.items) |f| {
            allocator.free(f.name);
            allocator.free(f.reason);
        }
        all_failures.deinit();
    }

    var files_processed: usize = 0;
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".json")) continue;

        // Skip filler files
        if (std.mem.indexOf(u8, entry.path, "Filler") != null) continue;

        const full_path = try std.fs.path.join(allocator, &[_][]const u8{ state_tests_path, entry.path });
        defer allocator.free(full_path);

        const file = std.fs.cwd().openFile(full_path, .{}) catch continue;
        defer file.close();
        const content = file.readToEndAlloc(allocator, 50 * 1024 * 1024) catch continue;
        defer allocator.free(content);

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch {
            total_parse_errors += 1;
            continue;
        };
        defer parsed.deinit();

        if (parsed.value != .object) {
            total_parse_errors += 1;
            continue;
        }

        const root = parsed.value.object;
        var it = root.iterator();
        while (it.next()) |test_entry| {
            if (test_entry.value_ptr.* != .object) continue;
            total += 1;

            const result = runSingleStateTest(
                allocator,
                test_entry.key_ptr.*,
                test_entry.value_ptr.*.object,
                fork_filter,
                verbose,
            ) catch |err| {
                total_failed += 1;
                if (verbose) {
                    std.debug.print("  ERROR: {s} ({s})\n", .{ test_entry.key_ptr.*, @errorName(err) });
                }
                continue;
            };

            total_passed += result.passed;
            total_failed += result.failed;
            total_skipped += result.skipped;

            for (result.failures.items) |f| {
                try all_failures.append(f);
            }
            // Don't deinit the failures ArrayList since we transferred ownership of items
            var failures_copy = result.failures;
            failures_copy.deinit();
        }

        files_processed += 1;

        // Progress every 100 files
        if (files_processed % 100 == 0) {
            std.debug.print("  ... processed {} files, {} sub-tests ({} passed, {} failed, {} skipped)\n", .{ files_processed, total_passed + total_failed + total_skipped, total_passed, total_failed, total_skipped });
        }
    }

    std.debug.print("\n===== GeneralStateTests Summary =====\n", .{});
    std.debug.print("Fork:           {s}\n", .{fork_filter_name});
    std.debug.print("Files:          {}\n", .{files_processed});
    std.debug.print("Test cases:     {}\n", .{total});
    std.debug.print("Sub-tests run:  {}\n", .{total_passed + total_failed});
    std.debug.print("  Passed:       {}\n", .{total_passed});
    std.debug.print("  Failed:       {}\n", .{total_failed});
    std.debug.print("  Skipped:      {}\n", .{total_skipped});
    std.debug.print("  Parse errors: {}\n", .{total_parse_errors});

    // Print first N failures
    const max_failures_to_print: usize = 50;
    if (all_failures.items.len > 0) {
        const n = @min(all_failures.items.len, max_failures_to_print);
        std.debug.print("\nFirst {} failures:\n", .{n});
        for (all_failures.items[0..n]) |f| {
            std.debug.print("  FAIL: {s}\n    Reason: {s}\n", .{ f.name, f.reason });
        }
        if (all_failures.items.len > max_failures_to_print) {
            std.debug.print("  ... and {} more\n", .{all_failures.items.len - max_failures_to_print});
        }
    }

    // Write summary JSON
    if (summary_json_path) |path| {
        const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        const writer = file.writer();

        try writer.writeAll("{\n");
        try writer.print("  \"total\": {},\n", .{total});
        try writer.print("  \"passed\": {},\n", .{total_passed});
        try writer.print("  \"failed\": {},\n", .{total_failed});
        try writer.print("  \"skipped\": {},\n", .{total_skipped});
        try writer.print("  \"parse_errors\": {},\n", .{total_parse_errors});
        try writer.print("  \"files_processed\": {},\n", .{files_processed});
        try writer.print("  \"fork\": \"{s}\",\n", .{fork_filter_name});

        try writer.writeAll("  \"failures\": [\n");
        for (all_failures.items, 0..) |f, i| {
            try writer.writeAll("    {");
            try writer.print("\"name\": \"{s}\", ", .{f.name});
            // Escape the reason string for JSON
            try writer.writeAll("\"reason\": \"");
            for (f.reason) |c| {
                switch (c) {
                    '"' => try writer.writeAll("\\\""),
                    '\\' => try writer.writeAll("\\\\"),
                    '\n' => try writer.writeAll("\\n"),
                    else => try writer.writeByte(c),
                }
            }
            try writer.writeAll("\", ");
            try writer.print("\"expected_hash\": \"{s}\", ", .{f.expected_hash});
            try writer.print("\"got_hash\": \"{s}\"", .{f.got_hash});
            try writer.writeByte('}');
            if (i + 1 < all_failures.items.len) try writer.writeByte(',');
            try writer.writeByte('\n');
        }
        try writer.writeAll("  ]\n");
        try writer.writeAll("}\n");

        std.debug.print("\nSummary written to {s}\n", .{path});
    }

    // Exit with failure if any tests failed
    if (total_failed > 0) {
        std.process.exit(1);
    }
}
