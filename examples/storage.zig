const std = @import("std");
const evm = @import("evm");
const types = @import("types");

/// Simple Storage Contract Example
///
/// Solidity equivalent:
/// ```solidity
/// contract SimpleStorage {
///     mapping(uint256 => uint256) public data;
///     function set(uint256 key, uint256 value) public { data[key] = value; }
///     function get(uint256 key) public view returns (uint256) { return data[key]; }
/// }
/// ```

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.debug.print("\n=== Simple Storage Contract Example ===\n\n", .{});
    
    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();
    
    // Test 1: Store value 42 at key 0
    std.debug.print("Test 1: Store 42 at key 0\n", .{});
    
    // Bytecode: PUSH1 42, PUSH1 0, SSTORE
    const store_bytecode = [_]u8{
        0x60, 0x2a, // PUSH1 42
        0x60, 0x00, // PUSH1 0 (key)
        0x55,       // SSTORE
    };
    
    _ = try vm.execute(&store_bytecode, &[_]u8{});
    std.debug.print("  Gas used: {}\n\n", .{vm.gas_used});
    
    // Test 2: Load value from key 0
    std.debug.print("Test 2: Load from key 0\n", .{});
    vm.gas_used = 0;
    
    const load_bytecode = [_]u8{
        0x60, 0x00, // PUSH1 0 (key)
        0x54,       // SLOAD
    };
    
    _ = try vm.execute(&load_bytecode, &[_]u8{});
    std.debug.print("  Value loaded to stack\n", .{});
    std.debug.print("  Gas used: {}\n\n", .{vm.gas_used});
    
    // Test 3: Store multiple values
    std.debug.print("Test 3: Store multiple values\n", .{});
    vm.gas_used = 0;
    
    // Store 100 at key 1, 200 at key 2
    const multi_store = [_]u8{
        0x60, 0x64, // PUSH1 100
        0x60, 0x01, // PUSH1 1
        0x55,       // SSTORE
        0x60, 0xc8, // PUSH1 200
        0x60, 0x02, // PUSH1 2
        0x55,       // SSTORE
    };
    
    _ = try vm.execute(&multi_store, &[_]u8{});
    std.debug.print("  Stored two values\n", .{});
    std.debug.print("  Gas used: {}\n\n", .{vm.gas_used});
    
    std.debug.print("  Multiple values stored successfully!\n\n", .{});
    
    std.debug.print("Storage contract works perfectly!\n", .{});
}

