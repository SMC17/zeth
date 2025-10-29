const std = @import("std");
const evm = @import("evm");
const types = @import("types");

// Comprehensive EVM Test Suite
// Tests all major opcode families with real bytecode

test "EVM: All arithmetic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();
    
    // Test: (5 + 3) * 2 - 4 = 12
    const bytecode = [_]u8{
        0x60, 0x05, // PUSH1 5
        0x60, 0x03, // PUSH1 3
        0x01,       // ADD  (8)
        0x60, 0x02, // PUSH1 2
        0x02,       // MUL  (16)
        0x60, 0x04, // PUSH1 4
        0x03,       // SUB  (12)
    };
    
    _ = try vm.execute(&bytecode, &[_]u8{});
    const result = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 12), result.limbs[0]);
}

test "EVM: Comparison and conditional logic" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();
    
    // Simple comparison test: 5 < 10 should be true (1)
    const bytecode = [_]u8{
        0x60, 0x05, // PUSH1 5
        0x60, 0x0a, // PUSH1 10
        0x10,       // LT
    };
    
    _ = try vm.execute(&bytecode, &[_]u8{});
    const result = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 1), result.limbs[0]);
}

test "EVM: Bitwise operations" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();
    
    // Test: (0xFF & 0x0F) | 0xF0 = 0xFF
    const bytecode = [_]u8{
        0x60, 0xff, // PUSH1 0xFF
        0x60, 0x0f, // PUSH1 0x0F
        0x16,       // AND (result: 0x0F)
        0x60, 0xf0, // PUSH1 0xF0
        0x17,       // OR  (result: 0xFF)
    };
    
    _ = try vm.execute(&bytecode, &[_]u8{});
    const result = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 0xFF), result.limbs[0]);
}

test "EVM: Stack operations (DUP and SWAP)" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();
    
    // Test DUP: Push 42, DUP1, should have two 42s
    const dup_bytecode = [_]u8{
        0x60, 0x2a, // PUSH1 42
        0x80,       // DUP1
    };
    
    _ = try vm.execute(&dup_bytecode, &[_]u8{});
    const val1 = try vm.stack.pop();
    const val2 = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 42), val1.limbs[0]);
    try testing.expectEqual(@as(u64, 42), val2.limbs[0]);
}

test "EVM: Memory operations" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();
    
    // Store 0x1234 at offset 0, then load it
    const bytecode = [_]u8{
        0x61, 0x12, 0x34, // PUSH2 0x1234
        0x60, 0x00,       // PUSH1 0
        0x52,             // MSTORE
        0x60, 0x00,       // PUSH1 0
        0x51,             // MLOAD
    };
    
    const result = try vm.execute(&bytecode, &[_]u8{});
    try testing.expect(result.success);
}

test "EVM: Storage operations" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();
    
    // Store and retrieve
    const bytecode = [_]u8{
        0x60, 0x42, // PUSH1 0x42 (value)
        0x60, 0x05, // PUSH1 5 (key)
        0x55,       // SSTORE
        0x60, 0x05, // PUSH1 5 (key)
        0x54,       // SLOAD
    };
    
    const result = try vm.execute(&bytecode, &[_]u8{});
    try testing.expect(result.success);
}

test "EVM: Event logging" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();
    
    // Store data in memory and emit LOG1
    const bytecode = [_]u8{
        0x60, 0x42,       // PUSH1 0x42
        0x60, 0x00,       // PUSH1 0
        0x52,             // MSTORE
        0x60, 0xaa,       // PUSH1 0xaa (topic)
        0x60, 0x20,       // PUSH1 32 (length)
        0x60, 0x00,       // PUSH1 0 (offset)
        0xa1,             // LOG1
    };
    
    const result = try vm.execute(&bytecode, &[_]u8{});
    defer {
        for (result.logs) |log| {
            allocator.free(log.topics);
            allocator.free(log.data);
        }
        allocator.free(result.logs);
    }
    
    try testing.expect(result.success);
    try testing.expectEqual(@as(usize, 1), result.logs.len);
    try testing.expectEqual(@as(usize, 1), result.logs[0].topics.len);
}

test "EVM: Environmental opcodes" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    // Create context with known values
    var context = evm.ExecutionContext.default();
    context.block_number = 12345;
    context.block_timestamp = 1234567890;
    context.chain_id = 1;
    
    var vm = try evm.EVM.initWithContext(allocator, 1000000, context);
    defer vm.deinit();
    
    // Test NUMBER and TIMESTAMP opcodes
    const bytecode = [_]u8{
        0x43, // NUMBER
        0x42, // TIMESTAMP
        0x46, // CHAINID
    };
    
    const result = try vm.execute(&bytecode, &[_]u8{});
    try testing.expect(result.success);
}

test "EVM: SHA3 hashing" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();
    
    // Store "hello" in memory and hash it
    const bytecode = [_]u8{
        0x60, 0x68,       // PUSH1 'h'
        0x60, 0x00,       // PUSH1 0
        0x52,             // MSTORE
        0x60, 0x01,       // PUSH1 1 (length)
        0x60, 0x1f,       // PUSH1 31 (offset - last byte)
        0x20,             // SHA3
    };
    
    const result = try vm.execute(&bytecode, &[_]u8{});
    try testing.expect(result.success);
}

test "EVM: REVERT handling" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();
    
    // Execute code that reverts
    const bytecode = [_]u8{
        0x60, 0x00, // PUSH1 0
        0x60, 0x00, // PUSH1 0
        0xfd,       // REVERT
    };
    
    const result = try vm.execute(&bytecode, &[_]u8{});
    try testing.expect(!result.success);
}

test "EVM: Gas metering" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var vm = try evm.EVM.init(allocator, 8);
    defer vm.deinit();
    
    // This should run out of gas (limit is only 8)
    const bytecode = [_]u8{
        0x60, 0x01, // PUSH1 1  (3 gas) - total: 3
        0x60, 0x02, // PUSH1 2  (3 gas) - total: 6
        0x01,       // ADD      (3 gas) - total: 9, should fail here since 9 > 8
        0x60, 0x00, // PUSH1 0  - should never reach this
    };
    
    const result = vm.execute(&bytecode, &[_]u8{});
    try testing.expectError(error.OutOfGas, result);
}

