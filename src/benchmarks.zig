const std = @import("std");
const evm = @import("evm");
const types = @import("types");
const crypto = @import("crypto");
const state = @import("state");

// Performance Benchmarks
// Quantify everything. No guessing.

const iterations = 10000;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Zeth Performance Benchmarks ===\n\n", .{});

    // Benchmark 1: U256 Addition
    {
        const start = std.time.nanoTimestamp();

        var result = types.U256.fromU64(0);
        for (0..iterations) |_| {
            result = result.add(types.U256.one());
        }

        const end = std.time.nanoTimestamp();
        const elapsed_ns = end - start;
        const ns_per_op = @divFloor(elapsed_ns, iterations);
        const ops_per_sec = @divFloor(1_000_000_000, ns_per_op);

        std.debug.print("U256 Addition:\n", .{});
        std.debug.print("  {} iterations\n", .{iterations});
        std.debug.print("  {} ns/op\n", .{ns_per_op});
        std.debug.print("  {} ops/sec\n\n", .{ops_per_sec});
    }

    // Benchmark 2: U256 Multiplication
    {
        const start = std.time.nanoTimestamp();

        const a = types.U256.fromU64(123456);
        const b = types.U256.fromU64(789);
        var result = types.U256.zero();

        for (0..iterations) |_| {
            result = a.mul(b);
        }

        const end = std.time.nanoTimestamp();
        const elapsed_ns = end - start;
        const ns_per_op = @divFloor(elapsed_ns, iterations);
        const ops_per_sec = @divFloor(1_000_000_000, ns_per_op);

        std.debug.print("U256 Multiplication:\n", .{});
        std.debug.print("  {} ns/op\n", .{ns_per_op});
        std.debug.print("  {} ops/sec\n\n", .{ops_per_sec});

        std.mem.doNotOptimizeAway(result);
    }

    // Benchmark 3: Keccak256 Hashing
    {
        const data = "The quick brown fox jumps over the lazy dog";
        var hash: [32]u8 = undefined;

        const start = std.time.nanoTimestamp();

        for (0..iterations) |_| {
            crypto.keccak256(data, &hash);
        }

        const end = std.time.nanoTimestamp();
        const elapsed_ns = end - start;
        const ns_per_op = @divFloor(elapsed_ns, iterations);
        const ops_per_sec = @divFloor(1_000_000_000, ns_per_op);
        const mb_per_sec = @divFloor(data.len * ops_per_sec, 1024 * 1024);

        std.debug.print("Keccak256 Hashing ({} bytes):\n", .{data.len});
        std.debug.print("  {} ns/op\n", .{ns_per_op});
        std.debug.print("  {} ops/sec\n", .{ops_per_sec});
        std.debug.print("  ~{} MB/s\n\n", .{mb_per_sec});
    }

    // Benchmark 4: EVM Simple Execution
    {
        var vm = try evm.EVM.init(allocator, 1000000);
        defer vm.deinit();

        // Simple ADD operation
        const bytecode = [_]u8{
            0x60, 0x05, // PUSH1 5
            0x60, 0x03, // PUSH1 3
            0x01, // ADD
        };

        const start = std.time.nanoTimestamp();

        for (0..iterations / 100) |_| {
            vm.gas_used = 0;
            _ = try vm.execute(&bytecode, &[_]u8{});
        }

        const end = std.time.nanoTimestamp();
        const elapsed_ns = end - start;
        const ns_per_exec = @divFloor(elapsed_ns, iterations / 100);
        const execs_per_sec = @divFloor(1_000_000_000, ns_per_exec);

        std.debug.print("EVM Execution (3 opcodes):\n", .{});
        std.debug.print("  {} ns/execution\n", .{ns_per_exec});
        std.debug.print("  {} executions/sec\n", .{execs_per_sec});
        std.debug.print("  ~{} opcodes/sec\n\n", .{execs_per_sec * 3});
    }

    // Benchmark 5: State journal checkpoint churn
    {
        var db = state.StateDB.init(allocator);
        defer db.deinit();

        var addr = types.Address.zero;
        addr.bytes[19] = 0x77;
        const key = types.U256.fromU64(1);
        try db.createAccount(addr);
        try db.setBalance(addr, types.U256.fromU64(1));
        try db.setStorage(addr, key, types.U256.fromU64(1));
        try db.setCode(addr, &[_]u8{ 0x60, 0x00, 0x00 });

        const start = std.time.nanoTimestamp();

        for (0..iterations) |i| {
            const sid = try db.snapshot();
            try db.setBalance(addr, types.U256.fromU64(@intCast(i + 2)));
            try db.setStorage(addr, key, types.U256.fromU64(@intCast(i + 3)));
            if ((i & 1) == 0) {
                try db.revertToSnapshot(sid);
            } else {
                try db.commitSnapshot(sid);
            }
        }

        const end = std.time.nanoTimestamp();
        const elapsed_ns = end - start;
        const ns_per_iter = @divFloor(elapsed_ns, iterations);
        const ops_per_sec = @divFloor(1_000_000_000, ns_per_iter);

        std.debug.print("State Journal Checkpoints:\n", .{});
        std.debug.print("  {} ns/iteration\n", .{ns_per_iter});
        std.debug.print("  {} checkpoint ops/sec\n\n", .{ops_per_sec});
    }

    // =========================================================================
    // Extended Benchmark Suite — throughput baselines for revm/evmone comparison
    // =========================================================================

    std.debug.print("--- Extended Benchmarks ---\n\n", .{});

    // Collect summary rows: name, ops/sec, ns/op
    var summary_names: [12][]const u8 = undefined;
    var summary_ops: [12]u64 = undefined;
    var summary_ns: [12]u64 = undefined;
    var summary_count: usize = 0;

    // Benchmark 6: Arithmetic throughput (ADD/MUL/SUB dispatch loop)
    // Bytecode: 1000 repetitions of PUSH1 1, PUSH1 2, ADD, POP (4 bytes each)
    {
        const reps = 1000;
        const pattern = [_]u8{ 0x60, 0x01, 0x60, 0x02, 0x01, 0x50 }; // PUSH1 1, PUSH1 2, ADD, POP
        const code_len = reps * pattern.len;
        var code_buf: [code_len]u8 = undefined;
        for (0..reps) |r| {
            @memcpy(code_buf[r * pattern.len ..][0..pattern.len], &pattern);
        }
        const bytecode = &code_buf;

        const N: u64 = 200;
        const total_opcodes = N * reps * 4; // 4 opcodes per rep

        const timer_start = std.time.nanoTimestamp();

        for (0..N) |_| {
            var vm = try evm.EVM.init(allocator, 10_000_000);
            defer vm.deinit();
            _ = try vm.execute(bytecode, &[_]u8{});
        }

        var elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() - timer_start);
        if (elapsed_ns == 0) elapsed_ns = 1;
        const opcodes_per_sec = @as(u64, @intFromFloat(@as(f64, @floatFromInt(total_opcodes)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0)));
        const ns_per_exec = elapsed_ns / N;

        std.debug.print("benchmark: arith_dispatch — {} ops/s ({} ns/exec, {} opcodes/s)\n", .{ N * 1_000_000_000 / elapsed_ns, ns_per_exec, opcodes_per_sec });
        summary_names[summary_count] = "arith_dispatch";
        summary_ops[summary_count] = opcodes_per_sec;
        summary_ns[summary_count] = ns_per_exec;
        summary_count += 1;
    }

    // Benchmark 7: Memory throughput (MSTORE/MLOAD 1000 sequential words)
    {
        // Bytecode: for each of 1000 offsets: PUSH32 value, PUSH2 offset, MSTORE
        // Then:     for each of 1000 offsets: PUSH2 offset, MLOAD, POP
        // Offsets: 0, 32, 64, ... , 31968
        const word_count = 1000;
        // Each MSTORE sequence: PUSH1 0xFF (2 bytes) + PUSH2 offset (3 bytes) + MSTORE (1 byte) = 6 bytes
        // Each MLOAD sequence:  PUSH2 offset (3 bytes) + MLOAD (1 byte) + POP (1 byte) = 5 bytes
        const store_pattern_len = 6;
        const load_pattern_len = 5;
        const code_len = word_count * store_pattern_len + word_count * load_pattern_len + 1; // +1 for STOP
        var code_buf: [code_len]u8 = undefined;

        var pos: usize = 0;
        for (0..word_count) |w| {
            const offset: u16 = @intCast(w * 32);
            code_buf[pos] = 0x60; // PUSH1
            code_buf[pos + 1] = 0xFF; // value byte
            code_buf[pos + 2] = 0x61; // PUSH2
            code_buf[pos + 3] = @intCast(offset >> 8);
            code_buf[pos + 4] = @intCast(offset & 0xFF);
            code_buf[pos + 5] = 0x52; // MSTORE
            pos += store_pattern_len;
        }
        for (0..word_count) |w| {
            const offset: u16 = @intCast(w * 32);
            code_buf[pos] = 0x61; // PUSH2
            code_buf[pos + 1] = @intCast(offset >> 8);
            code_buf[pos + 2] = @intCast(offset & 0xFF);
            code_buf[pos + 3] = 0x51; // MLOAD
            code_buf[pos + 4] = 0x50; // POP
            pos += load_pattern_len;
        }
        code_buf[pos] = 0x00; // STOP

        const bytecode = code_buf[0 .. pos + 1];
        const N: u64 = 100;
        const total_mem_ops = N * word_count * 2; // store + load

        const timer_start = std.time.nanoTimestamp();

        for (0..N) |_| {
            var vm = try evm.EVM.init(allocator, 100_000_000);
            defer vm.deinit();
            _ = try vm.execute(bytecode, &[_]u8{});
        }

        var elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() - timer_start);
        if (elapsed_ns == 0) elapsed_ns = 1;
        const ops_per_sec = @as(u64, @intFromFloat(@as(f64, @floatFromInt(total_mem_ops)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0)));
        const ns_per_exec = elapsed_ns / N;

        std.debug.print("benchmark: mem_throughput — {} mem_ops/s ({} ns/exec)\n", .{ ops_per_sec, ns_per_exec });
        summary_names[summary_count] = "mem_throughput";
        summary_ops[summary_count] = ops_per_sec;
        summary_ns[summary_count] = ns_per_exec;
        summary_count += 1;
    }

    // Benchmark 8: Storage throughput (SSTORE/SLOAD with StateDB)
    {
        const slot_count = 100;
        // SSTORE sequence: PUSH1 value, PUSH1 slot, SSTORE (5 bytes per slot)
        // SLOAD sequence: PUSH1 slot, SLOAD, POP (4 bytes per slot)
        const store_len = 5;
        const load_len = 4;
        const code_len = slot_count * store_len + slot_count * load_len + 1;
        var code_buf: [code_len]u8 = undefined;

        var pos: usize = 0;
        for (0..slot_count) |s| {
            code_buf[pos] = 0x60; // PUSH1 value
            code_buf[pos + 1] = @intCast(s + 1);
            code_buf[pos + 2] = 0x60; // PUSH1 slot
            code_buf[pos + 3] = @intCast(s);
            code_buf[pos + 4] = 0x55; // SSTORE
            pos += store_len;
        }
        for (0..slot_count) |s| {
            code_buf[pos] = 0x60; // PUSH1 slot
            code_buf[pos + 1] = @intCast(s);
            code_buf[pos + 2] = 0x54; // SLOAD
            code_buf[pos + 3] = 0x50; // POP
            pos += load_len;
        }
        code_buf[pos] = 0x00; // STOP

        const bytecode = code_buf[0 .. pos + 1];
        const N: u64 = 100;
        const total_storage_ops = N * slot_count * 2;

        var contract_addr = types.Address.zero;
        contract_addr.bytes[19] = 0xBB;

        const timer_start = std.time.nanoTimestamp();

        for (0..N) |_| {
            var db = state.StateDB.init(allocator);
            defer db.deinit();
            try db.createAccount(contract_addr);
            try db.setBalance(contract_addr, types.U256.fromU64(1_000_000));

            var ctx = evm.ExecutionContext.default();
            ctx.address = contract_addr;
            ctx.caller = contract_addr;
            var vm = try evm.EVM.initWithState(allocator, 100_000_000, ctx, &db);
            defer vm.deinit();
            _ = try vm.execute(bytecode, &[_]u8{});
        }

        var elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() - timer_start);
        if (elapsed_ns == 0) elapsed_ns = 1;
        const ops_per_sec = @as(u64, @intFromFloat(@as(f64, @floatFromInt(total_storage_ops)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0)));
        const ns_per_exec = elapsed_ns / N;

        std.debug.print("benchmark: storage_throughput — {} storage_ops/s ({} ns/exec)\n", .{ ops_per_sec, ns_per_exec });
        summary_names[summary_count] = "storage_throughput";
        summary_ops[summary_count] = ops_per_sec;
        summary_ns[summary_count] = ns_per_exec;
        summary_count += 1;
    }

    // Benchmark 9: SHA3 throughput (hash 32 bytes, 1000 times)
    {
        const hash_count = 1000;
        // Each iteration: PUSH1 32, PUSH1 0, SHA3, POP = 6 bytes
        // First, store 32 bytes in memory: PUSH32 <value>, PUSH1 0, MSTORE = 35 bytes
        const preamble_len = 35;
        const hash_pattern_len = 6;
        const code_len = preamble_len + hash_count * hash_pattern_len + 1;
        var code_buf: [code_len]u8 = undefined;

        // Preamble: PUSH32 0xDEAD...BEEF, PUSH1 0, MSTORE
        code_buf[0] = 0x7F; // PUSH32
        for (1..33) |i| {
            code_buf[i] = @intCast(i); // some non-zero data
        }
        code_buf[33] = 0x60; // PUSH1
        code_buf[34] = 0x00; // offset 0
        // Wait, MSTORE is missing. Let me recalculate.
        // Preamble: PUSH32 (33 bytes) + PUSH1 0 (2 bytes) + MSTORE (1 byte) = 36 bytes
        const actual_preamble_len = 36;
        const actual_code_len = actual_preamble_len + hash_count * hash_pattern_len + 1;
        var sha3_code: [actual_code_len]u8 = undefined;

        sha3_code[0] = 0x7F; // PUSH32
        for (1..33) |i| {
            sha3_code[i] = @intCast(i);
        }
        sha3_code[33] = 0x60; // PUSH1
        sha3_code[34] = 0x00; // offset 0
        sha3_code[35] = 0x52; // MSTORE

        var sha3_pos: usize = actual_preamble_len;
        for (0..hash_count) |_| {
            sha3_code[sha3_pos] = 0x60; // PUSH1 32
            sha3_code[sha3_pos + 1] = 0x20;
            sha3_code[sha3_pos + 2] = 0x60; // PUSH1 0
            sha3_code[sha3_pos + 3] = 0x00;
            sha3_code[sha3_pos + 4] = 0x20; // SHA3
            sha3_code[sha3_pos + 5] = 0x50; // POP
            sha3_pos += hash_pattern_len;
        }
        sha3_code[sha3_pos] = 0x00; // STOP

        const bytecode = sha3_code[0 .. sha3_pos + 1];
        const N: u64 = 50;
        const total_hashes = N * hash_count;

        const timer_start = std.time.nanoTimestamp();

        for (0..N) |_| {
            var vm = try evm.EVM.init(allocator, 100_000_000);
            defer vm.deinit();
            _ = try vm.execute(bytecode, &[_]u8{});
        }

        var elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() - timer_start);
        if (elapsed_ns == 0) elapsed_ns = 1;
        const hashes_per_sec = @as(u64, @intFromFloat(@as(f64, @floatFromInt(total_hashes)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0)));
        const ns_per_exec = elapsed_ns / N;

        std.debug.print("benchmark: sha3_throughput — {} hashes/s ({} ns/exec)\n", .{ hashes_per_sec, ns_per_exec });
        summary_names[summary_count] = "sha3_throughput";
        summary_ops[summary_count] = hashes_per_sec;
        summary_ns[summary_count] = ns_per_exec;
        summary_count += 1;
    }

    // Benchmark 10: CALL overhead (call empty contract 100 times)
    {
        const call_count = 100;
        var target_addr = types.Address.zero;
        target_addr.bytes[19] = 0xCC;
        var caller_addr = types.Address.zero;
        caller_addr.bytes[19] = 0xDD;

        // Bytecode for caller: 100x [PUSH1 0 (retSize), PUSH1 0 (retOff), PUSH1 0 (argsSize),
        //   PUSH1 0 (argsOff), PUSH1 0 (value), PUSH20 target (addr), PUSH3 gas, CALL, POP]
        // CALL args: gas, addr, value, argsOffset, argsSize, retOffset, retSize
        // = PUSH3 gas(4) + PUSH20 addr(22) + PUSH1 0(2) + PUSH1 0(2) + PUSH1 0(2) + PUSH1 0(2) + PUSH1 0(2) + CALL(1) + POP(1) = 38 bytes per call
        const call_pattern_len = 38;
        const total_code_len = call_count * call_pattern_len + 1;
        var call_code_buf: [total_code_len]u8 = undefined;

        var call_pos: usize = 0;
        for (0..call_count) |_| {
            // PUSH1 0 - retSize
            call_code_buf[call_pos] = 0x60;
            call_code_buf[call_pos + 1] = 0x00;
            // PUSH1 0 - retOffset
            call_code_buf[call_pos + 2] = 0x60;
            call_code_buf[call_pos + 3] = 0x00;
            // PUSH1 0 - argsSize
            call_code_buf[call_pos + 4] = 0x60;
            call_code_buf[call_pos + 5] = 0x00;
            // PUSH1 0 - argsOffset
            call_code_buf[call_pos + 6] = 0x60;
            call_code_buf[call_pos + 7] = 0x00;
            // PUSH1 0 - value
            call_code_buf[call_pos + 8] = 0x60;
            call_code_buf[call_pos + 9] = 0x00;
            // PUSH20 target address
            call_code_buf[call_pos + 10] = 0x73; // PUSH20
            @memcpy(call_code_buf[call_pos + 11 ..][0..20], &target_addr.bytes);
            // PUSH3 gas (0x100000 = ~1M gas for subcall)
            call_code_buf[call_pos + 31] = 0x62; // PUSH3
            call_code_buf[call_pos + 32] = 0x10;
            call_code_buf[call_pos + 33] = 0x00;
            call_code_buf[call_pos + 34] = 0x00;
            // CALL
            call_code_buf[call_pos + 35] = 0xF1;
            // POP (call result)
            call_code_buf[call_pos + 36] = 0x50;
            // pad
            call_code_buf[call_pos + 37] = 0x5B; // JUMPDEST (nop filler to keep alignment)
            call_pos += call_pattern_len;
        }
        call_code_buf[call_pos] = 0x00; // STOP

        const call_bytecode = call_code_buf[0 .. call_pos + 1];
        const N: u64 = 50;
        const total_calls = N * call_count;

        // Target contract code: just STOP
        const target_code = [_]u8{0x00};

        const timer_start = std.time.nanoTimestamp();

        for (0..N) |_| {
            var db = state.StateDB.init(allocator);
            defer db.deinit();
            try db.createAccount(caller_addr);
            try db.setBalance(caller_addr, types.U256.fromU64(1_000_000_000));
            try db.createAccount(target_addr);
            try db.setCode(target_addr, &target_code);

            var ctx = evm.ExecutionContext.default();
            ctx.address = caller_addr;
            ctx.caller = caller_addr;
            ctx.origin = caller_addr;
            var vm = try evm.EVM.initWithState(allocator, 500_000_000, ctx, &db);
            defer vm.deinit();
            _ = try vm.execute(call_bytecode, &[_]u8{});
        }

        var elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() - timer_start);
        if (elapsed_ns == 0) elapsed_ns = 1;
        const calls_per_sec = @as(u64, @intFromFloat(@as(f64, @floatFromInt(total_calls)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0)));
        const ns_per_exec = elapsed_ns / N;

        std.debug.print("benchmark: call_overhead — {} calls/s ({} ns/exec)\n", .{ calls_per_sec, ns_per_exec });
        summary_names[summary_count] = "call_overhead";
        summary_ops[summary_count] = calls_per_sec;
        summary_ns[summary_count] = ns_per_exec;
        summary_count += 1;
    }

    // Benchmark 11: CREATE overhead (50 creates with minimal init code)
    {
        const create_count = 50;
        var creator_addr = types.Address.zero;
        creator_addr.bytes[19] = 0xEE;

        // Init code that returns empty runtime code: PUSH1 0, PUSH1 0, RETURN (5 bytes)
        // CREATE args: value, offset, size
        // We need to put init code in memory first, then CREATE
        // Per create: PUSH3 initcode (3 bytes of init: 60 00 60 00 F3)
        //   Actually, store init code in memory:
        //   PUSH5 <initcode padded>, PUSH1 0, MSTORE (stores at offset 0)
        //   Then: PUSH1 5 (size), PUSH1 27 (offset = 32-5), PUSH1 0 (value), CREATE, POP
        //   = 2+2+1 + 2+2+2+1+1 = 13 bytes per create
        // Simpler: just store 5-byte init code once, then call CREATE N times
        // Init code: 60 00 60 00 F3 (PUSH1 0, PUSH1 0, RETURN) — returns empty code

        // Preamble: store init code in memory once
        // PUSH5 6000 6000 F3 0000 => big endian in 32 bytes at offset 0
        // Actually simpler: use individual MSTORE8 for 5 bytes
        // Or: PUSH5 bytes, PUSH1 0, MSTORE — puts them right-aligned at offset 0..31
        // The 5 bytes end up at positions 27-31 of the 32-byte word
        // So init code offset = 27, size = 5

        const preamble = [_]u8{
            0x64, // PUSH5
            0x60, 0x00, 0x60, 0x00, 0xF3, // init code: PUSH1 0, PUSH1 0, RETURN
            0x60, 0x00, // PUSH1 0 (memory offset)
            0x52, // MSTORE — stores the 32-byte word at offset 0, init code at bytes 27..31
        };

        // Per CREATE: PUSH1 5 (size), PUSH1 27 (offset), PUSH1 0 (value), CREATE, POP = 8 bytes
        const create_pattern = [_]u8{
            0x60, 0x05, // PUSH1 5 (size)
            0x60, 0x1B, // PUSH1 27 (offset, 0x1B = 27)
            0x60, 0x00, // PUSH1 0 (value)
            0xF0, // CREATE
            0x50, // POP
        };

        const total_code_len = preamble.len + create_count * create_pattern.len + 1;
        var create_code_buf: [total_code_len]u8 = undefined;
        @memcpy(create_code_buf[0..preamble.len], &preamble);
        var create_pos: usize = preamble.len;
        for (0..create_count) |_| {
            @memcpy(create_code_buf[create_pos..][0..create_pattern.len], &create_pattern);
            create_pos += create_pattern.len;
        }
        create_code_buf[create_pos] = 0x00; // STOP

        const create_bytecode = create_code_buf[0 .. create_pos + 1];
        const N: u64 = 50;
        const total_creates = N * create_count;

        const timer_start = std.time.nanoTimestamp();

        for (0..N) |_| {
            var db = state.StateDB.init(allocator);
            defer db.deinit();
            try db.createAccount(creator_addr);
            try db.setBalance(creator_addr, types.U256.fromU64(1_000_000_000));

            var ctx = evm.ExecutionContext.default();
            ctx.address = creator_addr;
            ctx.caller = creator_addr;
            ctx.origin = creator_addr;
            var vm = try evm.EVM.initWithState(allocator, 500_000_000, ctx, &db);
            defer vm.deinit();
            _ = try vm.execute(create_bytecode, &[_]u8{});
        }

        var elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() - timer_start);
        if (elapsed_ns == 0) elapsed_ns = 1;
        const creates_per_sec = @as(u64, @intFromFloat(@as(f64, @floatFromInt(total_creates)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0)));
        const ns_per_exec = elapsed_ns / N;

        std.debug.print("benchmark: create_overhead — {} creates/s ({} ns/exec)\n", .{ creates_per_sec, ns_per_exec });
        summary_names[summary_count] = "create_overhead";
        summary_ops[summary_count] = creates_per_sec;
        summary_ns[summary_count] = ns_per_exec;
        summary_count += 1;
    }

    // Benchmark 12: ERC-20 transfer simulation
    // Simulates: SLOAD balance_from, check >= amount, SUB, SSTORE balance_from,
    //            SLOAD balance_to, ADD, SSTORE balance_to
    // ~20 opcodes per "transfer", run 1000 iterations
    {
        var contract_addr = types.Address.zero;
        contract_addr.bytes[19] = 0xAA;

        // Slot 0 = balance_from (initial 1_000_000)
        // Slot 1 = balance_to   (initial 0)
        // Transfer amount = 1 per iteration
        //
        // Per transfer (~20 opcodes):
        //   PUSH1 0, SLOAD,            — load balance_from (slot 0)
        //   PUSH1 1, SWAP1, SUB,       — balance_from - 1
        //   PUSH1 0, SSTORE,           — store new balance_from
        //   PUSH1 1, SLOAD,            — load balance_to (slot 1)
        //   PUSH1 1, ADD,              — balance_to + 1
        //   PUSH1 1, SSTORE            — store new balance_to
        // = 18 opcodes per transfer (close to 20 with overhead)

        const transfer_pattern = [_]u8{
            0x60, 0x00, // PUSH1 0 (slot from)
            0x54, // SLOAD
            0x60, 0x01, // PUSH1 1 (amount)
            0x90, // SWAP1
            0x03, // SUB
            0x60, 0x00, // PUSH1 0 (slot from)
            0x55, // SSTORE
            0x60, 0x01, // PUSH1 1 (slot to)
            0x54, // SLOAD
            0x60, 0x01, // PUSH1 1 (amount)
            0x01, // ADD
            0x60, 0x01, // PUSH1 1 (slot to)
            0x55, // SSTORE
        };

        const transfer_count = 1000;
        const total_code_len = transfer_count * transfer_pattern.len + 1;
        var erc20_code: [total_code_len]u8 = undefined;
        for (0..transfer_count) |t| {
            @memcpy(erc20_code[t * transfer_pattern.len ..][0..transfer_pattern.len], &transfer_pattern);
        }
        erc20_code[transfer_count * transfer_pattern.len] = 0x00; // STOP

        const erc20_bytecode: []const u8 = erc20_code[0 .. transfer_count * transfer_pattern.len + 1];
        const N: u64 = 50;
        const total_transfers = N * transfer_count;

        const timer_start = std.time.nanoTimestamp();

        for (0..N) |_| {
            var db = state.StateDB.init(allocator);
            defer db.deinit();
            try db.createAccount(contract_addr);
            try db.setBalance(contract_addr, types.U256.fromU64(1));
            // Set initial balance_from = 1_000_000
            try db.setStorage(contract_addr, types.U256.fromU64(0), types.U256.fromU64(1_000_000));
            try db.setStorage(contract_addr, types.U256.fromU64(1), types.U256.fromU64(0));

            var ctx = evm.ExecutionContext.default();
            ctx.address = contract_addr;
            ctx.caller = contract_addr;
            ctx.origin = contract_addr;
            var vm = try evm.EVM.initWithState(allocator, 500_000_000, ctx, &db);
            defer vm.deinit();
            _ = try vm.execute(erc20_bytecode, &[_]u8{});
        }

        var elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() - timer_start);
        if (elapsed_ns == 0) elapsed_ns = 1;
        const transfers_per_sec = @as(u64, @intFromFloat(@as(f64, @floatFromInt(total_transfers)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0)));
        const ns_per_exec = elapsed_ns / N;

        std.debug.print("benchmark: erc20_transfer — {} transfers/s ({} ns/exec)\n", .{ transfers_per_sec, ns_per_exec });
        summary_names[summary_count] = "erc20_transfer";
        summary_ops[summary_count] = transfers_per_sec;
        summary_ns[summary_count] = ns_per_exec;
        summary_count += 1;
    }

    // Benchmark 13: U256 arithmetic micro-benchmark (raw type-level, not EVM)
    {
        const N: u64 = 1_000_000;

        // U256 add
        {
            const a = types.U256.fromU64(0xDEADBEEFCAFEBABE);
            const b = types.U256.fromU64(0x1234567890ABCDEF);
            var result = types.U256.zero();

            const start = std.time.nanoTimestamp();
            for (0..N) |_| {
                result = result.add(a);
                result = result.add(b);
            }
            var elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() - start);
            if (elapsed_ns == 0) elapsed_ns = 1;
            const ops = N * 2;
            const ops_per_sec = @as(u64, @intFromFloat(@as(f64, @floatFromInt(ops)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0)));
            const ns_per_op = elapsed_ns / ops;

            std.debug.print("benchmark: u256_add — {} ops/s ({} ns/op)\n", .{ ops_per_sec, ns_per_op });
            std.mem.doNotOptimizeAway(result);

            summary_names[summary_count] = "u256_add";
            summary_ops[summary_count] = ops_per_sec;
            summary_ns[summary_count] = ns_per_op;
            summary_count += 1;
        }

        // U256 mul
        {
            var a = types.U256.fromU64(0xDEADBEEF);
            const b = types.U256.fromU64(0xCAFEBABE);

            const start = std.time.nanoTimestamp();
            for (0..N) |_| {
                a = a.mul(b);
                // Feed result back to prevent hoisting
                a.limbs[0] = a.limbs[0] | 1; // keep non-zero
            }
            var elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() - start);
            if (elapsed_ns == 0) elapsed_ns = 1;
            const ops_per_sec = @as(u64, @intFromFloat(@as(f64, @floatFromInt(N)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0)));
            const ns_per_op = elapsed_ns / N;

            std.debug.print("benchmark: u256_mul — {} ops/s ({} ns/op)\n", .{ ops_per_sec, ns_per_op });
            std.mem.doNotOptimizeAway(a);

            summary_names[summary_count] = "u256_mul";
            summary_ops[summary_count] = ops_per_sec;
            summary_ns[summary_count] = ns_per_op;
            summary_count += 1;
        }

        // U256 div
        {
            const a = types.U256{ .limbs = [_]u64{ 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFF, 0, 0 } };
            const b = types.U256.fromU64(0xDEADBEEF);
            var result = types.U256.zero();

            const div_n: u64 = 100_000; // div is slower — fewer iterations
            const start = std.time.nanoTimestamp();
            for (0..div_n) |_| {
                result = a.div(b);
            }
            var elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() - start);
            if (elapsed_ns == 0) elapsed_ns = 1;
            const ops_per_sec = @as(u64, @intFromFloat(@as(f64, @floatFromInt(div_n)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0)));
            const ns_per_op = elapsed_ns / div_n;

            std.debug.print("benchmark: u256_div — {} ops/s ({} ns/op)\n", .{ ops_per_sec, ns_per_op });
            std.mem.doNotOptimizeAway(result);

            summary_names[summary_count] = "u256_div";
            summary_ops[summary_count] = ops_per_sec;
            summary_ns[summary_count] = ns_per_op;
            summary_count += 1;
        }
    }

    // Benchmark 14: Gas throughput (gas/second — the standard EVM benchmark metric)
    // Mixed workload: arithmetic, memory, storage, hashing
    // Reference: evmone does ~3.56B gas/sec on blake2b
    {
        var contract_addr = types.Address.zero;
        contract_addr.bytes[19] = 0xFF;

        // Mixed bytecode:
        //   Phase 1: 200x PUSH1+PUSH1+ADD+POP (arithmetic, ~3 gas each ADD = ~600 gas)
        //   Phase 2: 100x PUSH1+PUSH1+MSTORE (memory, ~6 gas each = ~600 gas)
        //   Phase 3: 50x PUSH1+PUSH1+SSTORE (storage, ~20000 gas cold write each = ~1M gas)
        //   Phase 4: 20x PUSH1 32+PUSH1 0+SHA3+POP (hash, ~36 gas each = ~720 gas)
        // Total gas should be dominated by SSTORE — realistic mixed workload

        const arith_reps = 200;
        const mem_reps = 100;
        const store_reps = 50;
        const hash_reps = 20;

        const arith_pattern = [_]u8{ 0x60, 0x01, 0x60, 0x02, 0x01, 0x50 }; // PUSH1 PUSH1 ADD POP
        const mem_pattern_len = 6; // PUSH1 val, PUSH2 off, MSTORE
        // SHA3 preamble: PUSH32 <data>, PUSH1 0, MSTORE (36 bytes)
        const sha3_preamble = 36;
        const sha3_pattern = [_]u8{ 0x60, 0x20, 0x60, 0x00, 0x20, 0x50 }; // PUSH1 32, PUSH1 0, SHA3, POP

        const max_code_len = arith_reps * arith_pattern.len +
            mem_reps * mem_pattern_len +
            store_reps * 5 + // store_pattern per rep with varying slot
            sha3_preamble + hash_reps * sha3_pattern.len + 1;

        var gas_code: [max_code_len]u8 = undefined;
        var gpos: usize = 0;

        // Phase 1: Arithmetic
        for (0..arith_reps) |_| {
            @memcpy(gas_code[gpos..][0..arith_pattern.len], &arith_pattern);
            gpos += arith_pattern.len;
        }

        // Phase 2: Memory
        for (0..mem_reps) |w| {
            const offset: u16 = @intCast(w * 32);
            gas_code[gpos] = 0x60; // PUSH1 value
            gas_code[gpos + 1] = 0xAB;
            gas_code[gpos + 2] = 0x61; // PUSH2 offset
            gas_code[gpos + 3] = @intCast(offset >> 8);
            gas_code[gpos + 4] = @intCast(offset & 0xFF);
            gas_code[gpos + 5] = 0x52; // MSTORE
            gpos += mem_pattern_len;
        }

        // Phase 3: Storage (varying slots)
        for (0..store_reps) |s| {
            gas_code[gpos] = 0x60; // PUSH1 value
            gas_code[gpos + 1] = 0x42;
            gas_code[gpos + 2] = 0x60; // PUSH1 slot
            gas_code[gpos + 3] = @intCast(s);
            gas_code[gpos + 4] = 0x55; // SSTORE
            gpos += 5;
        }

        // Phase 4: SHA3 (preamble + hashes)
        gas_code[gpos] = 0x7F; // PUSH32
        for (1..33) |i| {
            gas_code[gpos + i] = @intCast(i);
        }
        gas_code[gpos + 33] = 0x60; // PUSH1 0
        gas_code[gpos + 34] = 0x00;
        gas_code[gpos + 35] = 0x52; // MSTORE
        gpos += sha3_preamble;

        for (0..hash_reps) |_| {
            @memcpy(gas_code[gpos..][0..sha3_pattern.len], &sha3_pattern);
            gpos += sha3_pattern.len;
        }

        gas_code[gpos] = 0x00; // STOP
        gpos += 1;

        const gas_bytecode: []const u8 = gas_code[0..gpos];
        const N: u64 = 100;
        var total_gas: u64 = 0;

        const timer_start = std.time.nanoTimestamp();

        for (0..N) |_| {
            var db = state.StateDB.init(allocator);
            defer db.deinit();
            try db.createAccount(contract_addr);
            try db.setBalance(contract_addr, types.U256.fromU64(1));

            var ctx = evm.ExecutionContext.default();
            ctx.address = contract_addr;
            ctx.caller = contract_addr;
            ctx.origin = contract_addr;
            var vm = try evm.EVM.initWithState(allocator, 500_000_000, ctx, &db);
            defer vm.deinit();
            const result = try vm.execute(gas_bytecode, &[_]u8{});
            total_gas += result.gas_used;
        }

        var elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() - timer_start);
        if (elapsed_ns == 0) elapsed_ns = 1;
        const gas_per_sec = @as(u64, @intFromFloat(@as(f64, @floatFromInt(total_gas)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0)));
        const ns_per_exec = elapsed_ns / N;
        const avg_gas_per_exec = total_gas / N;

        std.debug.print("benchmark: gas_throughput — {} gas/s ({} ns/exec, {} gas/exec)\n", .{ gas_per_sec, ns_per_exec, avg_gas_per_exec });
        std.debug.print("  reference: evmone blake2b = 3.56B gas/s\n", .{});

        summary_names[summary_count] = "gas_throughput";
        summary_ops[summary_count] = gas_per_sec;
        summary_ns[summary_count] = ns_per_exec;
        summary_count += 1;
    }

    // =========================================================================
    // Summary Table
    // =========================================================================
    std.debug.print("\n=== Performance Summary ===\n", .{});
    std.debug.print("{s:<22} {s:>16} {s:>14}\n", .{ "Benchmark", "ops/s", "ns/op" });
    std.debug.print("{s:-<22} {s:->16} {s:->14}\n", .{ "", "", "" });
    for (0..summary_count) |i| {
        std.debug.print("{s:<22} {d:>16} {d:>14}\n", .{ summary_names[i], summary_ops[i], summary_ns[i] });
    }
    std.debug.print("{s:-<22} {s:->16} {s:->14}\n", .{ "", "", "" });

    std.debug.print("\n=== Benchmarks Complete ===\n", .{});
    std.debug.print("\nNote: These are unoptimized. Plenty of room for improvement.\n", .{});
}
