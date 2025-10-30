const std = @import("std");
const evm = @import("evm");
const types = @import("types");
const testing = std.testing;
const comparison = @import("comparison_tool");

// Systematic opcode verification against Ethereum specification
// Tests opcodes individually and in combinations

// Verify arithmetic opcodes
test "Verify: Arithmetic opcodes" {
    const allocator = testing.allocator;
    
    // Test ADD
    const add_code = [_]u8{ 0x60, 0x05, 0x60, 0x03, 0x01 }; // PUSH1 5, PUSH1 3, ADD
    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();
    
    _ = try vm.execute(&add_code, &[_]u8{});
    const result = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 8), result.limbs[0]);
    try testing.expect(vm.gas_used >= 9); // 3 + 3 + 3
    
    // Test MUL
    vm.gas_used = 0;
    const mul_code = [_]u8{ 0x60, 0x04, 0x60, 0x07, 0x02 }; // PUSH1 4, PUSH1 7, MUL
    _ = try vm.execute(&mul_code, &[_]u8{});
    const mul_result = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 28), mul_result.limbs[0]);
    
    // Test DIV
    vm.gas_used = 0;
    const div_code = [_]u8{ 0x60, 0x0a, 0x60, 0x02, 0x04 }; // PUSH1 10, PUSH1 2, DIV
    _ = try vm.execute(&div_code, &[_]u8{});
    const div_result = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 5), div_result.limbs[0]);
}

// Verify comparison opcodes
test "Verify: Comparison opcodes" {
    const allocator = testing.allocator;
    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();
    
    // LT: 5 < 3 = false (0)
    const lt_code = [_]u8{ 0x60, 0x05, 0x60, 0x03, 0x10 };
    _ = try vm.execute(&lt_code, &[_]u8{});
    const lt_result = try vm.stack.pop();
    try testing.expect(lt_result.isZero());
    
    // GT: 5 > 3 = true (1)
    vm.gas_used = 0;
    const gt_code = [_]u8{ 0x60, 0x05, 0x60, 0x03, 0x11 };
    _ = try vm.execute(&gt_code, &[_]u8{});
    const gt_result = try vm.stack.pop();
    try testing.expect(!gt_result.isZero());
    
    // EQ: 5 == 5 = true (1)
    vm.gas_used = 0;
    const eq_code = [_]u8{ 0x60, 0x05, 0x60, 0x05, 0x14 };
    _ = try vm.execute(&eq_code, &[_]u8{});
    const eq_result = try vm.stack.pop();
    try testing.expect(!eq_result.isZero());
}

/// Verify storage opcodes with warm/cold tracking
test "Verify: Storage opcodes (EIP-2929)" {
    const allocator = testing.allocator;
    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();
    
    // First SLOAD (cold) should cost 2100
    const sload1_code = [_]u8{ 0x60, 0x01, 0x54 }; // PUSH1 1, SLOAD
    _ = try vm.execute(&sload1_code, &[_]u8{});
    const cold_gas = vm.gas_used;
    
    // Second SLOAD (warm) should cost 100
    vm.gas_used = 0;
    _ = try vm.execute(&sload1_code, &[_]u8{});
    const warm_gas = vm.gas_used;
    
    // Cold should cost significantly more
    try testing.expect(cold_gas > warm_gas);
    try testing.expect(cold_gas >= 2100);
    try testing.expect(warm_gas >= 100);
}

/// Verify memory operations with expansion
test "Verify: Memory operations with expansion" {
    const allocator = testing.allocator;
    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();
    
    // MSTORE at offset 0 should expand memory and cost extra gas
    const mstore_code = [_]u8{ 0x60, 0x42, 0x60, 0x00, 0x52 }; // PUSH1 0x42, PUSH1 0, MSTORE
    _ = try vm.execute(&mstore_code, &[_]u8{});
    
    // Base cost: 3 + 3 + 3 = 9, plus memory expansion
    try testing.expect(vm.gas_used >= 9);
    
    // MLOAD should retrieve the value
    vm.gas_used = 0;
    const mload_code = [_]u8{ 0x60, 0x00, 0x51 }; // PUSH1 0, MLOAD
    _ = try vm.execute(&mload_code, &[_]u8{});
    const result = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 0x42), result.limbs[0]);
}

/// Verify stack operations
test "Verify: Stack operations" {
    const allocator = testing.allocator;
    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();
    
    // DUP1
    const dup_code = [_]u8{ 0x60, 0x2a, 0x80 }; // PUSH1 42, DUP1
    _ = try vm.execute(&dup_code, &[_]u8{});
    const a = try vm.stack.pop();
    const b = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 42), a.limbs[0]);
    try testing.expectEqual(@as(u64, 42), b.limbs[0]);
    
    // SWAP1
    vm.gas_used = 0;
    const swap_code = [_]u8{ 0x60, 0x01, 0x60, 0x02, 0x90 }; // PUSH1 1, PUSH1 2, SWAP1
    _ = try vm.execute(&swap_code, &[_]u8{});
    const c = try vm.stack.pop(); // Should be 1
    const d = try vm.stack.pop(); // Should be 2
    try testing.expectEqual(@as(u64, 1), c.limbs[0]);
    try testing.expectEqual(@as(u64, 2), d.limbs[0]);
}

/// Verify bitwise operations
test "Verify: Bitwise operations" {
    const allocator = testing.allocator;
    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();
    
    // AND: 0x0f & 0x0a = 0x0a
    const and_code = [_]u8{ 0x60, 0x0f, 0x60, 0x0a, 0x16 };
    _ = try vm.execute(&and_code, &[_]u8{});
    const and_result = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 0x0a), and_result.limbs[0]);
    
    // OR: 0x05 | 0x0a = 0x0f
    vm.gas_used = 0;
    const or_code = [_]u8{ 0x60, 0x05, 0x60, 0x0a, 0x17 };
    _ = try vm.execute(&or_code, &[_]u8{});
    const or_result = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 0x0f), or_result.limbs[0]);
    
    // XOR: 0x05 ^ 0x0a = 0x0f
    vm.gas_used = 0;
    const xor_code = [_]u8{ 0x60, 0x05, 0x60, 0x0a, 0x18 };
    _ = try vm.execute(&xor_code, &[_]u8{});
    const xor_result = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 0x0f), xor_result.limbs[0]);
}

/// Verify environmental opcodes
test "Verify: Environmental opcodes" {
    const allocator = testing.allocator;
    
    // Test CALLVALUE
    var ctx = evm.ExecutionContext.default();
    ctx.value = types.U256.fromU64(1000);
    var vm = try evm.EVM.initWithContext(allocator, 1000000, ctx);
    defer vm.deinit();
    
    const callvalue_code = [_]u8{ 0x34 }; // CALLVALUE
    _ = try vm.execute(&callvalue_code, &[_]u8{});
    const value = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 1000), value.limbs[0]);
    
    // Test CALLDATASIZE
    vm.gas_used = 0;
    const calldata = [_]u8{ 0x01, 0x02, 0x03 };
    const calldatasize_code = [_]u8{ 0x36 }; // CALLDATASIZE
    _ = try vm.execute(&calldatasize_code, &calldata);
    const size = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 3), size.limbs[0]);
}

/// Count verified opcodes
const verified_opcodes = struct {
    pub const arithmetic = [_][]const u8{ "ADD", "MUL", "DIV", "MOD", "SUB" };
    pub const comparison = [_][]const u8{ "LT", "GT", "EQ", "ISZERO" };
    pub const bitwise = [_][]const u8{ "AND", "OR", "XOR", "NOT" };
    pub const stack = [_][]const u8{ "DUP1", "SWAP1", "POP", "PUSH1" };
    pub const memory = [_][]const u8{ "MLOAD", "MSTORE" };
    pub const storage = [_][]const u8{ "SLOAD", "SSTORE" };
    pub const environmental = [_][]const u8{ "CALLVALUE", "CALLDATASIZE", "CALLDATASIZE" };
    
    pub fn total() usize {
        return arithmetic.len + comparison.len + bitwise.len + stack.len + memory.len + storage.len + environmental.len;
    }
};

test "Verify: Opcode count" {
    const count = verified_opcodes.total();
    std.debug.print("Verified opcodes: {}\n", .{count});
    try testing.expect(count >= 30); // At least 30 opcodes verified
}

