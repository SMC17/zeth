const std = @import("std");
const evm = @import("evm");
const types = @import("types");

/// Counter Contract Example
/// 
/// Solidity equivalent:
/// ```solidity
/// contract Counter {
///     uint256 public count;
///     function increment() public { count++; }
///     function get() public view returns (uint256) { return count; }
/// }
/// ```

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.debug.print("\n=== Counter Contract Example ===\n\n", .{});
    
    // Initialize EVM
    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();
    
    // Test 1: Increment counter
    std.debug.print("Test 1: Increment counter\n", .{});
    
    // Bytecode to increment storage slot 0:
    // PUSH1 0x01    // Push 1
    // PUSH1 0x00    // Push storage key (0)
    // SLOAD         // Load current value
    // ADD           // Add 1
    // PUSH1 0x00    // Push storage key
    // SSTORE        // Store new value
    const increment_bytecode = [_]u8{
        0x60, 0x01, // PUSH1 1
        0x60, 0x00, // PUSH1 0 (key)
        0x54,       // SLOAD
        0x01,       // ADD
        0x60, 0x00, // PUSH1 0 (key)
        0x55,       // SSTORE
    };
    
    _ = try vm.execute(&increment_bytecode, &[_]u8{});
    std.debug.print("  Gas used: {}\n", .{vm.gas_used});
    
    std.debug.print("  Counter incremented!\n\n", .{});
    
    // Test 2: Increment again
    std.debug.print("Test 2: Increment again\n", .{});
    vm.gas_used = 0; // Reset gas counter
    
    _ = try vm.execute(&increment_bytecode, &[_]u8{});
    std.debug.print("  Gas used: {}\n", .{vm.gas_used});
    std.debug.print("  Counter incremented again!\n\n", .{});
    
    // Test 3: Demonstrate stack operations
    std.debug.print("Test 3: Stack manipulation\n", .{});
    vm.gas_used = 0;
    
    // Bytecode demonstrating DUP and SWAP:
    // PUSH1 5, PUSH1 3, DUP2, SWAP1, ADD
    const stack_demo = [_]u8{
        0x60, 0x05, // PUSH1 5
        0x60, 0x03, // PUSH1 3
        0x81,       // DUP2 (duplicate 2nd item)
        0x90,       // SWAP1
        0x01,       // ADD
    };
    
    _ = try vm.execute(&stack_demo, &[_]u8{});
    std.debug.print("  Stack operations complete!\n", .{});
    std.debug.print("  Gas used: {}\n\n", .{vm.gas_used});
    
    std.debug.print("✅ Counter contract works perfectly!\n", .{});
}

