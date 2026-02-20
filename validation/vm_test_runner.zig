//! VMTests runner - executes Ethereum consensus VMTests against Zeth EVM.
//! Expects ethereum-tests (git clone https://github.com/ethereum/tests) at ./ethereum-tests
//! or path passed via --tests-dir.

const std = @import("std");
const evm = @import("evm");
const types = @import("types");
const state = @import("state");

const TestDir = "ethereum-tests";

fn parseHexBytes(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
    var s = hex;
    if (std.mem.startsWith(u8, s, "0x")) s = s[2..];
    if (s.len % 2 != 0) return error.InvalidHexLength;
    const out = try allocator.alloc(u8, s.len / 2);
    for (0..out.len) |i| {
        const hi = try hexCharToNibble(s[i * 2]);
        const lo = try hexCharToNibble(s[i * 2 + 1]);
        out[i] = (@as(u8, hi) << 4) | @as(u8, lo);
    }
    return out;
}

fn hexCharToNibble(c: u8) !u4 {
    return switch (c) {
        '0'...'9' => @as(u4, @intCast(c - '0')),
        'a'...'f' => @as(u4, @intCast(c - 'a' + 10)),
        'A'...'F' => @as(u4, @intCast(c - 'A' + 10)),
        else => error.InvalidHexChar,
    };
}

fn parseU256FromHex(hex: []const u8) !types.U256 {
    var s = hex;
    if (std.mem.startsWith(u8, s, "0x")) s = s[2..];
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

fn parseU64FromHex(hex: []const u8) !u64 {
    const u = try parseU256FromHex(hex);
    if (u.limbs[1] != 0 or u.limbs[2] != 0 or u.limbs[3] != 0) return error.Overflow;
    return u.limbs[0];
}

fn postStateMatches(db: *state.StateDB, post: std.json.Value) !bool {
    const obj = post.object;
    var it = obj.iterator();
    while (it.next()) |entry| {
        const addr = try parseAddress(entry.key_ptr.*);
        const acc = entry.value_ptr.*.object;

        if (acc.get("balance")) |v| {
            const expected = try parseU256FromHex(v.string);
            const got = try db.getBalance(addr);
            if (!got.eq(expected)) return false;
        }
        if (acc.get("storage")) |st| {
            const storage_obj = st.object;
            var sit = storage_obj.iterator();
            while (sit.next()) |se| {
                const key = try parseU256FromHex(se.key_ptr.*);
                const expected = try parseU256FromHex(se.value_ptr.*.string);
                const got = try db.getStorage(addr, key);
                if (!got.eq(expected)) return false;
            }
        }
    }
    return true;
}

const VectorOutput = struct {
    name: []const u8,
    bytecode_hex: []const u8,
    calldata_hex: []const u8,
    gas_limit: u64,
    gas_used: u64,
    success: bool,
    return_data_hex: []const u8,
};

fn runSingleVmTestForVector(
    allocator: std.mem.Allocator,
    name: []const u8,
    test_obj: std.json.ObjectMap,
) !?VectorOutput {
    const exec_val = test_obj.get("exec") orelse return null;
    const exec = exec_val.object;
    const pre_val = test_obj.get("pre") orelse return null;

    const code_hex = exec.get("code").?.string;
    const code = try parseHexBytes(allocator, code_hex);
    defer allocator.free(code);

    const data_hex = exec.get("data").?.string;
    var data_owned: ?[]const u8 = null;
    const data: []const u8 = if (data_hex.len > 2) blk: {
        data_owned = try parseHexBytes(allocator, data_hex);
        break :blk data_owned.?;
    } else &[_]u8{};
    defer if (data_owned) |d| allocator.free(d);

    const gas_limit = try parseU64FromHex(exec.get("gas").?.string);
    const address = try parseAddress(exec.get("address").?.string);
    const caller = try parseAddress(exec.get("caller").?.string);
    const origin = try parseAddress(exec.get("origin").?.string);
    const value = try parseU256FromHex(exec.get("value").?.string);

    var db = state.StateDB.init(allocator);
    defer db.deinit();
    try loadStateFromPre(allocator, &db, pre_val);

    var ctx = evm.ExecutionContext.default();
    ctx.address = address;
    ctx.caller = caller;
    ctx.origin = origin;
    ctx.value = value;

    var vm = try evm.EVM.initWithState(allocator, gas_limit, ctx, &db);
    defer vm.deinit();

    const result = vm.execute(code, data) catch {
        return VectorOutput{
            .name = try allocator.dupe(u8, name),
            .bytecode_hex = try allocator.dupe(u8, code_hex),
            .calldata_hex = try allocator.dupe(u8, if (data_hex.len > 2) data_hex else "0x"),
            .gas_limit = gas_limit,
            .gas_used = vm.gas_used,
            .success = false,
            .return_data_hex = try allocator.dupe(u8, "0x"),
        };
    };
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    var return_hex: []const u8 = "0x";
    if (result.return_data.len > 0) {
        var buf = try allocator.alloc(u8, 2 + result.return_data.len * 2);
        buf[0] = '0';
        buf[1] = 'x';
        const h = "0123456789abcdef";
        for (result.return_data, 0..) |b, i| {
            buf[2 + i * 2] = h[b >> 4];
            buf[2 + i * 2 + 1] = h[b & 0xf];
        }
        return_hex = buf;
    }
    defer if (result.return_data.len > 0) allocator.free(return_hex);

    return VectorOutput{
        .name = try allocator.dupe(u8, name),
        .bytecode_hex = try allocator.dupe(u8, code_hex),
        .calldata_hex = try allocator.dupe(u8, if (data_hex.len > 2) data_hex else "0x"),
        .gas_limit = gas_limit,
        .gas_used = vm.gas_used,
        .success = result.success,
        .return_data_hex = try allocator.dupe(u8, return_hex),
    };
}

fn runSingleVmTest(
    allocator: std.mem.Allocator,
    _: []const u8,
    test_obj: std.json.ObjectMap,
) !bool {
    const exec_val = test_obj.get("exec") orelse return false;
    const exec = exec_val.object;
    const env_val = test_obj.get("env") orelse return false;
    _ = env_val;
    const pre_val = test_obj.get("pre") orelse return false;

    const code_hex = exec.get("code").?.string;
    const code = try parseHexBytes(allocator, code_hex);
    defer allocator.free(code);

    const data_hex = exec.get("data").?.string;
    var data_owned: ?[]const u8 = null;
    const data: []const u8 = if (data_hex.len > 2) blk: {
        data_owned = try parseHexBytes(allocator, data_hex);
        break :blk data_owned.?;
    } else &[_]u8{};
    defer if (data_owned) |d| allocator.free(d);

    const gas_limit = try parseU64FromHex(exec.get("gas").?.string);
    const address = try parseAddress(exec.get("address").?.string);
    const caller = try parseAddress(exec.get("caller").?.string);
    const origin = try parseAddress(exec.get("origin").?.string);
    const value = try parseU256FromHex(exec.get("value").?.string);

    var db = state.StateDB.init(allocator);
    defer db.deinit();
    try loadStateFromPre(allocator, &db, pre_val);

    var ctx = evm.ExecutionContext.default();
    ctx.address = address;
    ctx.caller = caller;
    ctx.origin = origin;
    ctx.value = value;

    var vm = try evm.EVM.initWithState(allocator, gas_limit, ctx, &db);
    defer vm.deinit();

    const result = vm.execute(code, data) catch {
        if (test_obj.get("post") == null) {
            return true;
        }
        return false;
    };
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    if (test_obj.get("post")) |post_val| {
        const match = try postStateMatches(&db, post_val);
        if (!match) return false;
    }
    if (test_obj.get("gas")) |gas_val| {
        const expected_remaining = try parseU64FromHex(gas_val.string);
        const gas_used = vm.gas_used;
        const actual_remaining = gas_limit -| gas_used;
        if (actual_remaining != expected_remaining) return false;
    }
    if (test_obj.get("out")) |out_val| {
        var expected_owned: ?[]const u8 = null;
        const expected_out = if (out_val.string.len > 2) blk: {
            expected_owned = try parseHexBytes(allocator, out_val.string);
            break :blk expected_owned.?;
        } else &[_]u8{};
        defer if (expected_owned) |o| allocator.free(o);
        if (!std.mem.eql(u8, result.return_data, expected_out)) return false;
    }
    return true;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = std.process.args();
    _ = args.skip();
    var tests_dir: []const u8 = TestDir;
    var convert_mode = false;
    var out_path: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--tests-dir")) {
            if (args.next()) |p| tests_dir = p;
        } else if (std.mem.eql(u8, arg, "--convert")) {
            convert_mode = true;
        } else if (std.mem.eql(u8, arg, "--out")) {
            if (args.next()) |p| out_path = p;
        }
    }

    const vm_tests_path = try std.fmt.allocPrint(allocator, "{s}/VMTests", .{tests_dir});
    defer allocator.free(vm_tests_path);

    var dir = std.fs.cwd().openDir(vm_tests_path, .{ .iterate = true }) catch {
        std.debug.print("VMTests not found at {s}. Clone: git clone https://github.com/ethereum/tests {s}\n", .{ vm_tests_path, tests_dir });
        std.debug.print("Skipping VM validation (optional).\n", .{});
        return;
    };
    defer dir.close();

    if (convert_mode) {
        if (out_path == null) {
            std.debug.print("--convert requires --out <path>\n", .{});
            std.process.exit(1);
        }
        var vectors = std.ArrayList(VectorOutput).init(allocator);
        defer {
            for (vectors.items) |v| {
                allocator.free(v.name);
                allocator.free(v.bytecode_hex);
                allocator.free(v.calldata_hex);
                allocator.free(v.return_data_hex);
            }
            vectors.deinit();
        }
        var walker = try dir.walk(allocator);
        defer walker.deinit();
        while (try walker.next()) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".json")) continue;
            const full_path = try std.fs.path.join(allocator, &[_][]const u8{ vm_tests_path, entry.path });
            defer allocator.free(full_path);
            const content = std.fs.cwd().readFileAlloc(allocator, full_path, 20 * 1024 * 1024) catch continue;
            defer allocator.free(content);
            var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch continue;
            defer parsed.deinit();
            const root = parsed.value.object;
            var it = root.iterator();
            while (it.next()) |te| {
                const vec = runSingleVmTestForVector(allocator, te.key_ptr.*, te.value_ptr.*.object) catch null;
                if (vec) |v| try vectors.append(v);
            }
        }
        const output = .{ .vectors = vectors.items, .generated_at = std.time.timestamp(), .count = vectors.items.len };
        const f = try std.fs.cwd().createFile(out_path.?, .{ .truncate = true });
        defer f.close();
        try std.json.stringify(output, .{ .whitespace = .indent_2 }, f.writer());
        std.debug.print("Wrote {} vectors to {s}\n", .{ vectors.items.len, out_path.? });
        return;
    }

    var total: usize = 0;
    var passed: usize = 0;
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".json")) continue;

        const full_path = try std.fs.path.join(allocator, &[_][]const u8{ vm_tests_path, entry.path });
        defer allocator.free(full_path);

        const file = std.fs.cwd().openFile(full_path, .{}) catch continue;
        defer file.close();
        const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch continue;
        defer allocator.free(content);

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch continue;
        defer parsed.deinit();

        const root = parsed.value.object;
        var it = root.iterator();
        while (it.next()) |test_entry| {
            total += 1;
            const ok = runSingleVmTest(allocator, test_entry.key_ptr.*, test_entry.value_ptr.*.object) catch false;
            if (ok) passed += 1 else {
                if (passed + (total - passed) <= 20) {
                    std.debug.print("FAIL: {s}/{s}\n", .{ entry.path, test_entry.key_ptr.* });
                }
            }
        }
    }

    std.debug.print("VMTests: {}/{} passed\n", .{ passed, total });
    if (total > 0 and passed < total) {
        std.process.exit(1);
    }
}
