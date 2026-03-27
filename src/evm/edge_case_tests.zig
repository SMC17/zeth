const std = @import("std");
const evm = @import("evm");
const types = @import("types");
const state = @import("state");

// Edge Case Tests for EVM - Boundary Conditions
// We find the limits. We document them. We handle them.

test "EVM: Stack depth limit enforcement" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    // Try to push 1025 items (limit is 1024)
    // Build bytecode: 1025 PUSH1 instructions
    var bytecode = try std.ArrayList(u8).initCapacity(allocator, 2050);
    defer bytecode.deinit();

    for (0..1025) |_| {
        try bytecode.append(0x60); // PUSH1
        try bytecode.append(0x01); // value 1
    }

    const result = vm.execute(bytecode.items, &[_]u8{});

    // Should fail with stack overflow
    try testing.expectError(error.StackOverflow, result);
}

test "EVM: Stack underflow detection" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    // Try to pop from empty stack
    const bytecode = [_]u8{
        0x50, // POP (stack is empty!)
    };

    const result = vm.execute(&bytecode, &[_]u8{});
    try testing.expectError(error.StackUnderflow, result);
}

test "EVM: Gas limit enforcement" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 8);
    defer vm.deinit();

    // Try to execute more than 8 gas worth
    const bytecode = [_]u8{
        0x60, 0x01, // PUSH1 (3 gas) - total: 3
        0x60, 0x02, // PUSH1 (3 gas) - total: 6
        0x01, // ADD   (3 gas) - total: 9, should fail here
        0x60, 0x00, // PUSH1 - should never reach
    };

    const result = vm.execute(&bytecode, &[_]u8{});
    try testing.expectError(error.OutOfGas, result);
}

test "EVM: Memory expansion beyond limits" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    // Try to access very large memory offset
    // Note: this will work but allocate memory
    const bytecode = [_]u8{
        0x60, 0x42, // PUSH1 0x42
        0x61, 0x10, 0x00, // PUSH2 0x1000 (large offset)
        0x52, // MSTORE
    };

    const result = try vm.execute(&bytecode, &[_]u8{});
    try testing.expect(result.success);

    // Verify memory expanded
    try testing.expect(vm.memory.data.items.len >= 0x1000 + 32);
}

test "EVM: Division by zero handling" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    const bytecode = [_]u8{
        0x60, 0x0a, // PUSH1 10
        0x60, 0x00, // PUSH1 0
        0x04, // DIV (10 / 0)
    };

    const result = try vm.execute(&bytecode, &[_]u8{});
    try testing.expect(result.success);

    const value = try vm.stack.pop();
    try testing.expect(value.isZero()); // Should return 0 per spec
}

test "EVM: Invalid opcode handling" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    // 0xFF is SELFDESTRUCT but could test truly invalid
    const bytecode = [_]u8{
        0x0c, // Invalid opcode (not defined in spec)
    };

    const result = vm.execute(&bytecode, &[_]u8{});
    try testing.expectError(error.InvalidOpcode, result);
}

test "EVM: JUMPDEST validation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    // Valid jump to JUMPDEST
    const bytecode = [_]u8{
        0x60, 0x04, // PUSH1 4
        0x56, // JUMP (to position 4)
        0x00, // STOP (should skip this)
        0x5b, // JUMPDEST (position 4)
        0x60, 0x42, // PUSH1 0x42
    };

    const result = try vm.execute(&bytecode, &[_]u8{});
    try testing.expect(result.success);
}

test "EVM: DUP with insufficient stack" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    // Try DUP2 with only 1 item on stack
    const bytecode = [_]u8{
        0x60, 0x01, // PUSH1 1 (1 item on stack)
        0x81, // DUP2 (tries to copy 2nd item - doesn't exist!)
    };

    const result = vm.execute(&bytecode, &[_]u8{});
    try testing.expectError(error.StackUnderflow, result);
}

test "EVM: SWAP with insufficient stack" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    // Try SWAP2 with only 1 item
    const bytecode = [_]u8{
        0x60, 0x01, // PUSH1 1
        0x91, // SWAP2 (needs at least 3 items!)
    };

    const result = vm.execute(&bytecode, &[_]u8{});
    try testing.expectError(error.StackUnderflow, result);
}

test "EVM: Maximum PUSH32 value" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    // PUSH32 with 32 bytes of 0xFF
    var bytecode = try std.ArrayList(u8).initCapacity(allocator, 2050);
    defer bytecode.deinit();

    try bytecode.append(0x7f); // PUSH32
    for (0..32) |_| {
        try bytecode.append(0xff);
    }

    const result = try vm.execute(bytecode.items, &[_]u8{});
    try testing.expect(result.success);
}

test "EVM: Memory growth patterns" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    // Store at increasing offsets to test memory expansion
    const bytecode = [_]u8{
        0x60, 0x01, 0x60, 0x00, 0x52, // MSTORE at 0
        0x60, 0x02, 0x60, 0x20, 0x52, // MSTORE at 32
        0x60, 0x03, 0x60, 0x40, 0x52, // MSTORE at 64
        0x60, 0x04, 0x60, 0x60, 0x52, // MSTORE at 96
    };

    const result = try vm.execute(&bytecode, &[_]u8{});
    try testing.expect(result.success);
    try testing.expect(vm.memory.data.items.len >= 128);
}

test "EVM: Consecutive operations stress test" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    // Chain many operations
    const bytecode = [_]u8{
        0x60, 0x0a, // PUSH1 10
        0x60, 0x05, // PUSH1 5
        0x01, // ADD (15)
        0x60, 0x02, // PUSH1 2
        0x02, // MUL (30)
        0x60, 0x03, // PUSH1 3
        0x04, // DIV (10)
        0x60, 0x07, // PUSH1 7
        0x06, // MOD (3)
        0x60, 0x01, // PUSH1 1
        0x01, // ADD (4)
    };

    const result = try vm.execute(&bytecode, &[_]u8{});
    try testing.expect(result.success);

    const final = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 4), final.limbs[0]);
}

test "EVM: Empty bytecode execution" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    const bytecode = [_]u8{};

    const result = try vm.execute(&bytecode, &[_]u8{});
    try testing.expect(result.success);
    try testing.expectEqual(@as(u64, 0), vm.gas_used);
}

test "EVM: ISZERO edge cases" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    // Test ISZERO with actual zero
    const bytecode1 = [_]u8{
        0x60, 0x00, // PUSH1 0
        0x15, // ISZERO
    };

    _ = try vm.execute(&bytecode1, &[_]u8{});
    const result1 = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 1), result1.limbs[0]);

    // Test ISZERO with non-zero
    vm.gas_used = 0;
    const bytecode2 = [_]u8{
        0x60, 0x01, // PUSH1 1
        0x15, // ISZERO
    };

    _ = try vm.execute(&bytecode2, &[_]u8{});
    const result2 = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 0), result2.limbs[0]);
}

test "EVM: Bitwise NOT correctness" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    // NOT 0 should be all 1s
    const bytecode = [_]u8{
        0x60, 0x00, // PUSH1 0
        0x19, // NOT
    };

    _ = try vm.execute(&bytecode, &[_]u8{});
    const result = try vm.stack.pop();

    try testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFFF), result.limbs[0]);
}

// ============================================================================
// SELFDESTRUCT accounting edge tests
// ============================================================================

test "EVM: SELFDESTRUCT to self with balance zeros balance" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    // Create account 0xaa with balance 100
    var addr_aa = types.Address{ .bytes = [_]u8{0} ** 20 };
    addr_aa.bytes[19] = 0xaa;

    try db.createAccount(addr_aa);
    try db.setBalance(addr_aa, types.U256.fromU64(100));

    // Code: PUSH1 0xaa, SELFDESTRUCT
    // The address on stack for selfdestruct is the beneficiary (self).
    // PUSH1 only pushes 1 byte, so we push 0xaa which becomes 0x00..00aa.
    // That matches our address since only byte[19] = 0xaa.
    const code = [_]u8{
        0x60, 0xaa, // PUSH1 0xaa
        0xff, // SELFDESTRUCT
    };

    var ctx = evm.ExecutionContext.default();
    ctx.address = addr_aa;

    var vm = try evm.EVM.initWithState(allocator, 100000, ctx, &db);
    defer vm.deinit();

    // Pre-warm self address per EIP-2929 (as a real tx would)
    try vm.warm_accounts.put(addr_aa, {});

    const result = try vm.execute(&code, &[_]u8{});
    try testing.expect(result.success);

    // Account should be destroyed: no longer exists in state
    try testing.expect(!db.exists(addr_aa));

    // Balance should be zero (not doubled). destroyAccount removes the account,
    // and since beneficiary == self with non-zero balance the transfer is skipped.
    const balance = db.getBalance(addr_aa) catch types.U256.zero();
    try testing.expect(balance.isZero());

    // Gas: 3 (PUSH1) + 5000 (selfdestruct base) + 100 (warm self access) = 5103
    try testing.expectEqual(@as(u64, 5103), result.gas_used);

    // Refund: 4800 for first selfdestruct
    try testing.expectEqual(@as(u64, 4800), result.gas_refund);
}

test "EVM: SELFDESTRUCT double-destruct same tx refunds only once" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var addr_bb = types.Address{ .bytes = [_]u8{0} ** 20 };
    addr_bb.bytes[19] = 0xbb;

    try db.createAccount(addr_bb);
    try db.setBalance(addr_bb, types.U256.fromU64(50));

    // Code: PUSH1 0xbb, SELFDESTRUCT
    const code = [_]u8{
        0x60, 0xbb, // PUSH1 0xbb
        0xff, // SELFDESTRUCT
    };

    var ctx = evm.ExecutionContext.default();
    ctx.address = addr_bb;

    // First execution
    var vm1 = try evm.EVM.initWithState(allocator, 100000, ctx, &db);
    defer vm1.deinit();
    try vm1.warm_accounts.put(addr_bb, {});

    const result1 = try vm1.execute(&code, &[_]u8{});
    try testing.expect(result1.success);
    try testing.expectEqual(@as(u64, 4800), result1.gas_refund);

    // Re-create account for second call (simulating within same tx context)
    try db.createAccount(addr_bb);

    // Second execution sharing the selfdestructed_accounts tracking
    var vm2 = try evm.EVM.initWithState(allocator, 100000, ctx, &db);
    defer vm2.deinit();
    try vm2.warm_accounts.put(addr_bb, {});

    // Copy the selfdestruct tracking from first execution
    try vm2.selfdestructed_accounts.put(addr_bb, {});
    vm2.gas_refund = result1.gas_refund;

    const result2 = try vm2.execute(&code, &[_]u8{});
    try testing.expect(result2.success);

    // Refund should still be 4800, not 9600 (second destruct does not add refund)
    try testing.expectEqual(@as(u64, 4800), result2.gas_refund);
}

// ============================================================================
// Memory expansion exact-gas golden tests
// ============================================================================

test "EVM: Memory expansion exact gas - MSTORE at offset 0 (1 word)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    // PUSH1 0x42, PUSH1 0x00, MSTORE
    const bytecode = [_]u8{
        0x60, 0x42, // PUSH1 0x42 (value)   -- 3 gas
        0x60, 0x00, // PUSH1 0x00 (offset)  -- 3 gas
        0x52, // MSTORE                      -- 3 base + mem_cost
    };

    // Memory: 0 -> 1 word (32 bytes)
    // mem_cost = (1*1/512 + 3*1) - 0 = 0 + 3 = 3
    // Total: 3 + 3 + 3 + 3 = 12
    const result = try vm.execute(&bytecode, &[_]u8{});
    try testing.expect(result.success);
    try testing.expectEqual(@as(u64, 12), result.gas_used);
}

test "EVM: Memory expansion exact gas - MSTORE at offset 32 (2 words)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    // First MSTORE to establish 1 word, then MSTORE at offset 32
    const bytecode = [_]u8{
        0x60, 0x01, // PUSH1 0x01           -- 3 gas
        0x60, 0x00, // PUSH1 0x00           -- 3 gas
        0x52, // MSTORE at 0                -- 3 + 3 = 6 gas (1 word expansion)
        0x60, 0x02, // PUSH1 0x02           -- 3 gas
        0x60, 0x20, // PUSH1 0x20 (32)      -- 3 gas
        0x52, // MSTORE at 32               -- 3 + mem_delta
    };

    // After first MSTORE: 1 word, cost = 0+3 = 3 (mem)
    // After second MSTORE: 2 words
    //   new_cost = (4/512 + 6) = 0 + 6 = 6
    //   old_cost = (1/512 + 3) = 0 + 3 = 3
    //   delta = 3
    // Total: 3+3+(3+3) + 3+3+(3+3) = 12 + 12 = 24
    const result = try vm.execute(&bytecode, &[_]u8{});
    try testing.expect(result.success);
    try testing.expectEqual(@as(u64, 24), result.gas_used);
}

test "EVM: Memory expansion exact gas - MSTORE at offset 992 (32 words)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    // First establish 2 words of memory, then jump to offset 992
    const bytecode = [_]u8{
        0x60, 0x01, // PUSH1 0x01           -- 3
        0x60, 0x00, // PUSH1 0x00           -- 3
        0x52, // MSTORE at 0                -- 3+3 = 6   (0->1 word)
        0x60, 0x02, // PUSH1 0x02           -- 3
        0x60, 0x20, // PUSH1 0x20           -- 3
        0x52, // MSTORE at 32               -- 3+3 = 6   (1->2 words)
        0x60, 0x03, // PUSH1 0x03           -- 3
        0x61, 0x03, 0xe0, // PUSH2 0x03e0 (992) -- 3
        0x52, // MSTORE at 992              -- 3+delta
    };

    // 992 + 32 = 1024 bytes = 32 words
    // new_cost(32) = (1024/512) + 96 = 2 + 96 = 98
    // old_cost(2) = (4/512) + 6 = 0 + 6 = 6
    // delta = 98 - 6 = 92
    // Third MSTORE gas: 3 + 92 = 95
    // Total: (3+3+6) + (3+3+6) + (3+3+95) = 12 + 12 + 101 = 125
    const result = try vm.execute(&bytecode, &[_]u8{});
    try testing.expect(result.success);
    try testing.expectEqual(@as(u64, 125), result.gas_used);
}

test "EVM: Memory expansion exact gas - MSTORE at offset 8160 (256 words = 8KB)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    // Single MSTORE at offset 8160: expands from 0 to 256 words
    const bytecode = [_]u8{
        0x60, 0x42, // PUSH1 0x42              -- 3
        0x61, 0x1f, 0xe0, // PUSH2 0x1fe0 (8160) -- 3
        0x52, // MSTORE                         -- 3 + mem_cost
    };

    // 8160 + 32 = 8192 bytes = 256 words
    // new_cost(256) = (256*256/512) + 3*256 = 128 + 768 = 896
    // old_cost(0) = 0
    // mem_cost = 896
    // Total: 3 + 3 + 3 + 896 = 905
    const result = try vm.execute(&bytecode, &[_]u8{});
    try testing.expect(result.success);
    try testing.expectEqual(@as(u64, 905), result.gas_used);
}

// ============================================================================
// Zero-length copy: no memory expansion
// ============================================================================

test "EVM: Zero-length CALLDATACOPY no memory expansion with large offset" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    // CALLDATACOPY(memOffset=0xFFFF, dataOffset=0, length=0)
    // Stack order: length pushed first (popped last)
    const bytecode = [_]u8{
        0x60, 0x00, // PUSH1 0x00 (length=0)      -- 3
        0x60, 0x00, // PUSH1 0x00 (dataOffset)     -- 3
        0x61, 0xff, 0xff, // PUSH2 0xFFFF (memOffset) -- 3
        0x37, // CALLDATACOPY                        -- 3 base + 0 mem + 0 copy
    };

    const result = try vm.execute(&bytecode, &[_]u8{});
    try testing.expect(result.success);

    // Gas: 3+3+3 (pushes) + 3 (base) + 0 (no expansion) + 0 (zero words) = 12
    try testing.expectEqual(@as(u64, 12), result.gas_used);

    // Memory should not have expanded
    try testing.expectEqual(@as(usize, 0), vm.memory.data.items.len);
}

test "EVM: Zero-length CODECOPY no memory expansion with large offset" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    // CODECOPY(memOffset=0x1000, codeOffset=0, length=0)
    const bytecode = [_]u8{
        0x60, 0x00, // PUSH1 0x00 (length=0)       -- 3
        0x60, 0x00, // PUSH1 0x00 (codeOffset)      -- 3
        0x61, 0x10, 0x00, // PUSH2 0x1000 (memOffset) -- 3
        0x39, // CODECOPY                             -- 3 base + 0 mem + 0 copy
    };

    const result = try vm.execute(&bytecode, &[_]u8{});
    try testing.expect(result.success);

    // Gas: 3+3+3 (pushes) + 3 (base) = 12
    try testing.expectEqual(@as(u64, 12), result.gas_used);
    try testing.expectEqual(@as(usize, 0), vm.memory.data.items.len);
}

test "EVM: Zero-length RETURNDATACOPY no memory expansion with large offset" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    // RETURNDATACOPY(memOffset=0x2000, returnDataOffset=0, length=0)
    const bytecode = [_]u8{
        0x60, 0x00, // PUSH1 0x00 (length=0)           -- 3
        0x60, 0x00, // PUSH1 0x00 (returnDataOffset)    -- 3
        0x61, 0x20, 0x00, // PUSH2 0x2000 (memOffset)   -- 3
        0x3e, // RETURNDATACOPY                          -- 3 base + 0 mem + 0 copy
    };

    const result = try vm.execute(&bytecode, &[_]u8{});
    try testing.expect(result.success);

    // Gas: 3+3+3 (pushes) + 3 (base) = 12
    try testing.expectEqual(@as(u64, 12), result.gas_used);
    try testing.expectEqual(@as(usize, 0), vm.memory.data.items.len);
}

// ============================================================================
// MSTORE8 single byte expansion tests
// ============================================================================

test "EVM: MSTORE8 at offset 0 expands to 1 word" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    // MSTORE8(offset=0, value=0x42)
    const bytecode = [_]u8{
        0x60, 0x42, // PUSH1 0x42 (value)    -- 3
        0x60, 0x00, // PUSH1 0x00 (offset)   -- 3
        0x53, // MSTORE8                      -- 3 base + mem_cost
    };

    // offset+1 = 1, new_words = ceil(1/32) = 1
    // mem_cost = (1/512 + 3) - 0 = 3
    // Total: 3 + 3 + 3 + 3 = 12
    const result = try vm.execute(&bytecode, &[_]u8{});
    try testing.expect(result.success);
    try testing.expectEqual(@as(u64, 12), result.gas_used);
}

test "EVM: MSTORE8 at offset 31 still 1 word" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    // MSTORE8(offset=31, value=0x42)
    const bytecode = [_]u8{
        0x60, 0x42, // PUSH1 0x42 (value)    -- 3
        0x60, 0x1f, // PUSH1 0x1f (31)       -- 3
        0x53, // MSTORE8                      -- 3 base + mem_cost
    };

    // offset+1 = 32, new_words = ceil(32/32) = 1
    // mem_cost = (1/512 + 3) - 0 = 3
    // Total: 3 + 3 + 3 + 3 = 12
    const result = try vm.execute(&bytecode, &[_]u8{});
    try testing.expect(result.success);
    try testing.expectEqual(@as(u64, 12), result.gas_used);
}

test "EVM: MSTORE8 at offset 32 expands to 2 words" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    // MSTORE8(offset=32, value=0x42)
    const bytecode = [_]u8{
        0x60, 0x42, // PUSH1 0x42 (value)    -- 3
        0x60, 0x20, // PUSH1 0x20 (32)       -- 3
        0x53, // MSTORE8                      -- 3 base + mem_cost
    };

    // offset+1 = 33, new_words = ceil(33/32) = 2
    // mem_cost = (4/512 + 6) - 0 = 0 + 6 = 6
    // Total: 3 + 3 + 3 + 6 = 15
    const result = try vm.execute(&bytecode, &[_]u8{});
    try testing.expect(result.success);
    try testing.expectEqual(@as(u64, 15), result.gas_used);
}

// ============================================================================
// SHA3 memory expansion + gas
// ============================================================================

test "EVM: SHA3 exact gas with pre-expanded memory" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    // First expand memory with MSTORE, then SHA3 over existing memory
    const bytecode = [_]u8{
        // MSTORE at offset 0 to expand memory to 32 bytes
        0x60, 0x42, // PUSH1 0x42              -- 3
        0x60, 0x00, // PUSH1 0x00              -- 3
        0x52, // MSTORE                         -- 3 + 3 (1 word expansion) = 6
        // SHA3(offset=0, length=32)
        0x60, 0x20, // PUSH1 0x20 (32 bytes)   -- 3
        0x60, 0x00, // PUSH1 0x00 (offset)     -- 3
        0x20, // SHA3                           -- 30 + 6*1 + 0 (no expansion) = 36
    };

    // Total: 3+3+6 + 3+3+36 = 12 + 42 = 54
    const result = try vm.execute(&bytecode, &[_]u8{});
    try testing.expect(result.success);
    try testing.expectEqual(@as(u64, 54), result.gas_used);

    // SHA3 result should be on the stack
    const hash_result = try vm.stack.pop();
    try testing.expect(!hash_result.isZero());
}

test "EVM: SHA3 with memory expansion from zero" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    // SHA3(offset=0, length=32) with no prior memory
    const bytecode = [_]u8{
        0x60, 0x20, // PUSH1 0x20 (32 bytes)   -- 3
        0x60, 0x00, // PUSH1 0x00 (offset)     -- 3
        0x20, // SHA3                           -- 30 + 6*1 + 3 (1 word expansion) = 39
    };

    // Total: 3 + 3 + 39 = 45
    const result = try vm.execute(&bytecode, &[_]u8{});
    try testing.expect(result.success);
    try testing.expectEqual(@as(u64, 45), result.gas_used);
}
