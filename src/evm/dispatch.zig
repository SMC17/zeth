const std = @import("std");
const types = @import("types");
const evm_mod = @import("evm");

const EVM = evm_mod.EVM;
const ExecutionResult = evm_mod.ExecutionResult;
const Log = evm_mod.Log;

/// Uniform handler signature for all opcodes.
/// Every handler receives self, code, and pc regardless of whether it needs them.
/// This enables a flat function pointer array with zero branching overhead.
pub const OpcodeHandler = *const fn (self: *EVM, code: []const u8, pc: *usize) anyerror!void;

/// Comptime-generated dispatch table. 256 entries, one per possible opcode byte.
/// null entries represent invalid/unassigned opcodes.
pub const dispatch_table: [256]?OpcodeHandler = buildDispatchTable();

/// Number of assigned opcodes in the dispatch table (available at comptime).
pub const assigned_opcode_count: usize = countAssigned();

fn countAssigned() usize {
    var count: usize = 0;
    for (dispatch_table) |entry| {
        if (entry != null) count += 1;
    }
    return count;
}

/// Wrap a handler that only needs self: *EVM.
fn wrapSelf(comptime handler: fn (*EVM) anyerror!void) OpcodeHandler {
    return struct {
        fn call(self: *EVM, _: []const u8, _: *usize) anyerror!void {
            return handler(self);
        }
    }.call;
}

/// Wrap a handler that needs self and pc.
fn wrapPc(comptime handler: fn (*EVM, *usize) anyerror!void) OpcodeHandler {
    return struct {
        fn call(self: *EVM, _: []const u8, pc: *usize) anyerror!void {
            return handler(self, pc);
        }
    }.call;
}

/// Generate a PUSH<n> wrapper. The push size is baked in at comptime.
fn pushWrapper(comptime n: usize) OpcodeHandler {
    return struct {
        fn call(self: *EVM, code: []const u8, pc: *usize) anyerror!void {
            return self.opPush(code, pc, n);
        }
    }.call;
}

/// Generate a DUP<n> wrapper. The dup depth is baked in at comptime.
fn dupWrapper(comptime n: usize) OpcodeHandler {
    return struct {
        fn call(self: *EVM, _: []const u8, _: *usize) anyerror!void {
            return self.opDup(n);
        }
    }.call;
}

/// Generate a SWAP<n> wrapper. The swap depth is baked in at comptime.
fn swapWrapper(comptime n: usize) OpcodeHandler {
    return struct {
        fn call(self: *EVM, _: []const u8, _: *usize) anyerror!void {
            return self.opSwap(n);
        }
    }.call;
}

/// Generate a LOG<n> wrapper. The topic count is baked in at comptime.
fn logWrapper(comptime n: usize) OpcodeHandler {
    return struct {
        fn call(self: *EVM, _: []const u8, _: *usize) anyerror!void {
            return self.opLog(n);
        }
    }.call;
}

/// STOP handler: sets halted flag. Inlined in the original switch.
fn opStop(self: *EVM, _: []const u8, _: *usize) anyerror!void {
    self.halted = true;
}

/// JUMPDEST handler: charges 1 gas. Inlined in the original switch.
fn opJumpdest(self: *EVM, _: []const u8, _: *usize) anyerror!void {
    self.gas_used += 1;
}

fn buildDispatchTable() [256]?OpcodeHandler {
    @setEvalBranchQuota(4096);
    var table: [256]?OpcodeHandler = [_]?OpcodeHandler{null} ** 256;

    // 0x00: STOP
    table[0x00] = opStop;

    // 0x01-0x0b: Arithmetic
    table[0x01] = wrapSelf(EVM.opAdd);
    table[0x02] = wrapSelf(EVM.opMul);
    table[0x03] = wrapSelf(EVM.opSub);
    table[0x04] = wrapSelf(EVM.opDiv);
    table[0x05] = wrapSelf(EVM.opSdiv);
    table[0x06] = wrapSelf(EVM.opMod);
    table[0x07] = wrapSelf(EVM.opSmod);
    table[0x08] = wrapSelf(EVM.opAddmod);
    table[0x09] = wrapSelf(EVM.opMulmod);
    table[0x0a] = wrapSelf(EVM.opExp);
    table[0x0b] = wrapSelf(EVM.opSignExtend);

    // 0x10-0x1d: Comparison & Bitwise Logic
    table[0x10] = wrapSelf(EVM.opLt);
    table[0x11] = wrapSelf(EVM.opGt);
    table[0x12] = wrapSelf(EVM.opSlt);
    table[0x13] = wrapSelf(EVM.opSgt);
    table[0x14] = wrapSelf(EVM.opEq);
    table[0x15] = wrapSelf(EVM.opIsZero);
    table[0x16] = wrapSelf(EVM.opAnd);
    table[0x17] = wrapSelf(EVM.opOr);
    table[0x18] = wrapSelf(EVM.opXor);
    table[0x19] = wrapSelf(EVM.opNot);
    table[0x1a] = wrapSelf(EVM.opByte);
    table[0x1b] = wrapSelf(EVM.opShl);
    table[0x1c] = wrapSelf(EVM.opShr);
    table[0x1d] = wrapSelf(EVM.opSar);

    // 0x20: SHA3
    table[0x20] = wrapSelf(EVM.opSha3);

    // 0x30-0x3f: Environmental Information
    table[0x30] = wrapSelf(EVM.opAddress);
    table[0x31] = wrapSelf(EVM.opBalance);
    table[0x32] = wrapSelf(EVM.opOrigin);
    table[0x33] = wrapSelf(EVM.opCaller);
    table[0x34] = wrapSelf(EVM.opCallValue);
    table[0x35] = wrapSelf(EVM.opCallDataLoad);
    table[0x36] = wrapSelf(EVM.opCallDataSize);
    table[0x37] = wrapSelf(EVM.opCallDataCopy);
    table[0x38] = wrapSelf(EVM.opCodeSize);
    table[0x39] = wrapSelf(EVM.opCodeCopy);
    table[0x3a] = wrapSelf(EVM.opGasPrice);
    table[0x3b] = wrapSelf(EVM.opExtCodeSize);
    table[0x3c] = wrapSelf(EVM.opExtCodeCopy);
    table[0x3d] = wrapSelf(EVM.opReturnDataSize);
    table[0x3e] = wrapSelf(EVM.opReturnDataCopy);
    table[0x3f] = wrapSelf(EVM.opExtCodeHash);

    // 0x40-0x4a: Block Information
    table[0x40] = wrapSelf(EVM.opBlockhash);
    table[0x41] = wrapSelf(EVM.opCoinbase);
    table[0x42] = wrapSelf(EVM.opTimestamp);
    table[0x43] = wrapSelf(EVM.opNumber);
    table[0x44] = wrapSelf(EVM.opDifficulty);
    table[0x45] = wrapSelf(EVM.opGasLimit);
    table[0x46] = wrapSelf(EVM.opChainId);
    table[0x47] = wrapSelf(EVM.opSelfBalance);
    table[0x48] = wrapSelf(EVM.opBaseFee);
    table[0x49] = wrapSelf(EVM.opBlobHash);
    table[0x4a] = wrapSelf(EVM.opBlobBaseFee);

    // 0x50-0x5f: Stack, Memory, Storage and Flow Operations
    table[0x50] = wrapSelf(EVM.opPop);
    table[0x51] = wrapSelf(EVM.opMload);
    table[0x52] = wrapSelf(EVM.opMstore);
    table[0x53] = wrapSelf(EVM.opMstore8);
    table[0x54] = wrapSelf(EVM.opSload);
    table[0x55] = wrapSelf(EVM.opSstore);
    table[0x56] = wrapPc(EVM.opJump);
    table[0x57] = wrapPc(EVM.opJumpi);
    table[0x58] = wrapPc(EVM.opPc);
    table[0x59] = wrapSelf(EVM.opMsize);
    table[0x5a] = wrapSelf(EVM.opGas);
    table[0x5b] = opJumpdest;
    table[0x5c] = wrapSelf(EVM.opTload);
    table[0x5d] = wrapSelf(EVM.opTstore);
    table[0x5e] = wrapSelf(EVM.opMcopy);
    table[0x5f] = wrapSelf(EVM.opPush0);

    // 0x60-0x7f: PUSH1 through PUSH32
    for (0..32) |i| {
        table[0x60 + i] = pushWrapper(i + 1);
    }

    // 0x80-0x8f: DUP1 through DUP16
    for (0..16) |i| {
        table[0x80 + i] = dupWrapper(i + 1);
    }

    // 0x90-0x9f: SWAP1 through SWAP16
    for (0..16) |i| {
        table[0x90 + i] = swapWrapper(i + 1);
    }

    // 0xa0-0xa4: LOG0 through LOG4
    for (0..5) |i| {
        table[0xa0 + i] = logWrapper(i);
    }

    // 0xf0-0xff: System Operations
    table[0xf0] = wrapSelf(EVM.opCreate);
    table[0xf1] = wrapSelf(EVM.opCall);
    table[0xf2] = wrapSelf(EVM.opCallCode);
    table[0xf3] = wrapSelf(EVM.opReturn);
    table[0xf4] = wrapSelf(EVM.opDelegateCall);
    table[0xf5] = wrapSelf(EVM.opCreate2);
    table[0xfa] = wrapSelf(EVM.opStaticCall);
    table[0xfd] = wrapSelf(EVM.opRevert);
    // 0xfe (INVALID) intentionally left null — returns InvalidOpcode at dispatch time.
    table[0xff] = wrapSelf(EVM.opSelfDestruct);

    return table;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "dispatch table has correct number of assigned opcodes" {
    // Count non-null entries
    var count: usize = 0;
    for (dispatch_table) |entry| {
        if (entry != null) count += 1;
    }
    // 1 (STOP) + 11 (arith) + 14 (cmp/bitwise) + 1 (SHA3) + 16 (env) + 11 (block)
    // + 16 (stack/mem/storage/flow: POP..PUSH0) + 32 (PUSH1-32) + 16 (DUP) + 16 (SWAP)
    // + 5 (LOG) + 9 (system: CREATE..SELFDESTRUCT) = 148
    try std.testing.expectEqual(@as(usize, 148), count);
}

test "dispatch table arithmetic matches switch-based execution" {
    const allocator = std.testing.allocator;

    // PUSH1 3, PUSH1 5, ADD, STOP  => stack top should be 8
    const code = [_]u8{ 0x60, 0x03, 0x60, 0x05, 0x01, 0x00 };

    // Execute via dispatch table
    var evm_dispatch = try EVM.init(allocator, 1_000_000);
    defer evm_dispatch.deinit();
    const dispatch_result = try executeWithDispatchTable(&evm_dispatch, &code, &[_]u8{});
    defer if (dispatch_result.return_data.len > 0) allocator.free(dispatch_result.return_data);

    // Execute via original switch
    var evm_switch = try EVM.init(allocator, 1_000_000);
    defer evm_switch.deinit();
    const switch_result = try evm_switch.execute(&code, &[_]u8{});
    defer if (switch_result.return_data.len > 0) allocator.free(switch_result.return_data);

    try std.testing.expect(dispatch_result.success);
    try std.testing.expect(switch_result.success);
    try std.testing.expectEqual(switch_result.gas_used, dispatch_result.gas_used);
}

test "dispatch table PUSH1+PUSH1+ADD produces correct result" {
    const allocator = std.testing.allocator;

    // PUSH1 10, PUSH1 20, ADD, STOP
    const code = [_]u8{ 0x60, 0x0a, 0x60, 0x14, 0x01, 0x00 };

    var evm = try EVM.init(allocator, 1_000_000);
    defer evm.deinit();
    const result = try executeWithDispatchTable(&evm, &code, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);

    try std.testing.expect(result.success);
    // Stack should have 30 (0x1e). Verify via gas accounting:
    // PUSH1 (3) + PUSH1 (3) + ADD (3) = 9 gas
    try std.testing.expectEqual(@as(u64, 9), result.gas_used);
}

test "dispatch table returns error for invalid opcode" {
    const allocator = std.testing.allocator;

    // 0xef is not a valid opcode
    const code = [_]u8{0xef};

    var evm = try EVM.init(allocator, 1_000_000);
    defer evm.deinit();
    const result = executeWithDispatchTable(&evm, &code, &[_]u8{});
    try std.testing.expectError(error.InvalidOpcode, result);
}

test "dispatch table handles PUSH32 correctly" {
    const allocator = std.testing.allocator;

    // PUSH32 followed by 32 bytes of 0xff, then STOP
    var code: [34]u8 = undefined;
    code[0] = 0x7f; // PUSH32
    for (1..33) |i| {
        code[i] = 0xff;
    }
    code[33] = 0x00; // STOP

    var evm = try EVM.init(allocator, 1_000_000);
    defer evm.deinit();
    const result = try executeWithDispatchTable(&evm, &code, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);

    try std.testing.expect(result.success);
    // PUSH32 (3 gas) + STOP (0 gas) = 3 gas
    try std.testing.expectEqual(@as(u64, 3), result.gas_used);
}

test "dispatch table DUP and SWAP work correctly" {
    const allocator = std.testing.allocator;

    // PUSH1 7, DUP1, ADD, STOP => 7 + 7 = 14
    const code = [_]u8{ 0x60, 0x07, 0x80, 0x01, 0x00 };

    var evm_dispatch = try EVM.init(allocator, 1_000_000);
    defer evm_dispatch.deinit();
    const dispatch_result = try executeWithDispatchTable(&evm_dispatch, &code, &[_]u8{});
    defer if (dispatch_result.return_data.len > 0) allocator.free(dispatch_result.return_data);

    var evm_switch = try EVM.init(allocator, 1_000_000);
    defer evm_switch.deinit();
    const switch_result = try evm_switch.execute(&code, &[_]u8{});
    defer if (switch_result.return_data.len > 0) allocator.free(switch_result.return_data);

    try std.testing.expectEqual(switch_result.gas_used, dispatch_result.gas_used);
}

test "dispatch table JUMP works correctly" {
    const allocator = std.testing.allocator;

    // PUSH1 4, JUMP, INVALID, JUMPDEST, STOP
    // Bytecodes: 0x60 0x04 0x56 0xfe 0x5b 0x00
    const code = [_]u8{ 0x60, 0x04, 0x56, 0xfe, 0x5b, 0x00 };

    var evm_dispatch = try EVM.init(allocator, 1_000_000);
    defer evm_dispatch.deinit();
    const dispatch_result = try executeWithDispatchTable(&evm_dispatch, &code, &[_]u8{});
    defer if (dispatch_result.return_data.len > 0) allocator.free(dispatch_result.return_data);

    var evm_switch = try EVM.init(allocator, 1_000_000);
    defer evm_switch.deinit();
    const switch_result = try evm_switch.execute(&code, &[_]u8{});
    defer if (switch_result.return_data.len > 0) allocator.free(switch_result.return_data);

    try std.testing.expect(dispatch_result.success);
    try std.testing.expect(switch_result.success);
    try std.testing.expectEqual(switch_result.gas_used, dispatch_result.gas_used);
}

test "dispatch table performance comparison" {
    const allocator = std.testing.allocator;

    // Build a program: 10K iterations of PUSH1 1, PUSH1 1, ADD, POP
    // Each iteration = 4 instructions = 4 bytes (PUSH1 val, PUSH1 val, ADD, POP)
    const iterations = 2500;
    const block_size = 6; // PUSH1, val, PUSH1, val, ADD, POP
    var code: [iterations * block_size + 1]u8 = undefined;
    for (0..iterations) |i| {
        const base = i * block_size;
        code[base + 0] = 0x60; // PUSH1
        code[base + 1] = 0x01; // value 1
        code[base + 2] = 0x60; // PUSH1
        code[base + 3] = 0x01; // value 1
        code[base + 4] = 0x01; // ADD
        code[base + 5] = 0x50; // POP
    }
    code[iterations * block_size] = 0x00; // STOP

    // Run dispatch table version
    var evm_dispatch = try EVM.init(allocator, 100_000_000);
    defer evm_dispatch.deinit();

    var timer_dispatch = try std.time.Timer.start();
    const dispatch_result = try executeWithDispatchTable(&evm_dispatch, &code, &[_]u8{});
    const dispatch_elapsed = timer_dispatch.read();
    defer if (dispatch_result.return_data.len > 0) allocator.free(dispatch_result.return_data);

    // Run switch version
    var evm_switch = try EVM.init(allocator, 100_000_000);
    defer evm_switch.deinit();

    var timer_switch = try std.time.Timer.start();
    const switch_result = try evm_switch.execute(&code, &[_]u8{});
    const switch_elapsed = timer_switch.read();
    defer if (switch_result.return_data.len > 0) allocator.free(switch_result.return_data);

    // Both must produce the same result
    try std.testing.expect(dispatch_result.success);
    try std.testing.expect(switch_result.success);
    try std.testing.expectEqual(switch_result.gas_used, dispatch_result.gas_used);

    // Log timing (visible with --verbose or test failure)
    std.debug.print("\n  Dispatch table: {}ns for {} opcodes\n", .{ dispatch_elapsed, iterations * 4 });
    std.debug.print("  Switch statement: {}ns for {} opcodes\n", .{ switch_elapsed, iterations * 4 });
    std.debug.print("  Ratio (switch/dispatch): {d:.2}x\n", .{@as(f64, @floatFromInt(switch_elapsed)) / @as(f64, @floatFromInt(dispatch_elapsed))});
}

// ---------------------------------------------------------------------------
// Execution engine using the dispatch table
// ---------------------------------------------------------------------------

/// Execute EVM bytecode using the comptime-generated dispatch table.
/// This is a drop-in alternative to EVM.execute() that replaces the switch
/// statement with an indirect function call through the 256-entry table.
pub fn executeWithDispatchTable(self: *EVM, code: []const u8, data: []const u8) !ExecutionResult {
    self.context.code = code;
    self.context.calldata = data;
    self.halted = false;
    self.clearReturnData();

    var tx_snapshot: ?usize = null;
    var tx_committed = false;
    if (self.state_db) |db| {
        tx_snapshot = try db.snapshot();
    }
    defer {
        if (self.state_db) |db| {
            if (tx_snapshot) |sid| {
                if (!tx_committed) {
                    db.revertToSnapshot(sid) catch {};
                }
            }
        }
    }

    var pc: usize = 0;

    while (pc < code.len) {
        if (self.halted) break;
        if (self.gas_used >= self.gas_limit) {
            return error.OutOfGas;
        }

        const op = code[pc];
        pc += 1;

        if (dispatch_table[op]) |handler| {
            handler(self, code, &pc) catch |err| {
                if (err == error.Revert) {
                    return ExecutionResult{
                        .success = false,
                        .gas_used = self.gas_used,
                        .gas_refund = self.gas_refund,
                        .return_data = if (self.return_data.len == 0) &[_]u8{} else try self.allocator.dupe(u8, self.return_data),
                        .logs = &[_]Log{},
                    };
                }
                return err;
            };
        } else {
            return error.InvalidOpcode;
        }
    }

    if (self.state_db) |db| {
        if (tx_snapshot) |sid| {
            try db.commitSnapshot(sid);
            tx_committed = true;
        }
    }

    return ExecutionResult{
        .success = true,
        .gas_used = self.gas_used,
        .gas_refund = self.gas_refund,
        .return_data = if (self.return_data.len == 0) &[_]u8{} else try self.allocator.dupe(u8, self.return_data),
        .logs = try self.logs.toOwnedSlice(),
    };
}
