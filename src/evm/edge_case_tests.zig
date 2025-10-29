const std = @import("std");
const evm = @import("evm");
const types = @import("types");

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
    defer bytecode.deinit(allocator);
    
    for (0..1025) |_| {
        try bytecode.append(allocator, 0x60); // PUSH1
        try bytecode.append(allocator, 0x01); // value 1
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
        0x01,       // ADD   (3 gas) - total: 9, should fail here
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
        0x60, 0x42,       // PUSH1 0x42
        0x61, 0x10, 0x00, // PUSH2 0x1000 (large offset)
        0x52,             // MSTORE
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
        0x04,       // DIV (10 / 0)
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
        0x56,       // JUMP (to position 4)
        0x00,       // STOP (should skip this)
        0x5b,       // JUMPDEST (position 4)
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
        0x81,       // DUP2 (tries to copy 2nd item - doesn't exist!)
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
        0x91,       // SWAP2 (needs at least 3 items!)
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
    defer bytecode.deinit(allocator);
    
    try bytecode.append(allocator, 0x7f); // PUSH32
    for (0..32) |_| {
        try bytecode.append(allocator, 0xff);
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
        0x01,       // ADD (15)
        0x60, 0x02, // PUSH1 2
        0x02,       // MUL (30)
        0x60, 0x03, // PUSH1 3
        0x04,       // DIV (10)
        0x60, 0x07, // PUSH1 7
        0x06,       // MOD (3)
        0x60, 0x01, // PUSH1 1
        0x01,       // ADD (4)
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
        0x15,       // ISZERO
    };
    
    _ = try vm.execute(&bytecode1, &[_]u8{});
    const result1 = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 1), result1.limbs[0]);
    
    // Test ISZERO with non-zero
    vm.gas_used = 0;
    const bytecode2 = [_]u8{
        0x60, 0x01, // PUSH1 1
        0x15,       // ISZERO
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
        0x19,       // NOT
    };
    
    _ = try vm.execute(&bytecode, &[_]u8{});
    const result = try vm.stack.pop();
    
    try testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFFF), result.limbs[0]);
}

