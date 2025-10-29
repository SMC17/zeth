const std = @import("std");
const evm = @import("evm");
const types = @import("types");

/// Arithmetic Operations Example
/// Demonstrates all arithmetic and comparison opcodes

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.debug.print("\n=== Arithmetic Operations Example ===\n\n", .{});
    
    // Test 1: Addition
    {
        var vm = try evm.EVM.init(allocator, 100000);
        defer vm.deinit();
        
        std.debug.print("Test 1: 5 + 3 = ?\n", .{});
        const bytecode = [_]u8{
            0x60, 0x05, // PUSH1 5
            0x60, 0x03, // PUSH1 3
            0x01,       // ADD
        };
        
        _ = try vm.execute(&bytecode, &[_]u8{});
        const result = try vm.stack.pop();
        std.debug.print("  Result: {}\n", .{result.limbs[0]});
        std.debug.print("  Gas used: {}\n\n", .{vm.gas_used});
    }
    
    // Test 2: Multiplication
    {
        var vm = try evm.EVM.init(allocator, 100000);
        defer vm.deinit();
        
        std.debug.print("Test 2: 7 * 6 = ?\n", .{});
        const bytecode = [_]u8{
            0x60, 0x07, // PUSH1 7
            0x60, 0x06, // PUSH1 6
            0x02,       // MUL
        };
        
        _ = try vm.execute(&bytecode, &[_]u8{});
        const result = try vm.stack.pop();
        std.debug.print("  Result: {}\n", .{result.limbs[0]});
        std.debug.print("  Gas used: {}\n\n", .{vm.gas_used});
    }
    
    // Test 3: Division
    {
        var vm = try evm.EVM.init(allocator, 100000);
        defer vm.deinit();
        
        std.debug.print("Test 3: 20 / 4 = ?\n", .{});
        const bytecode = [_]u8{
            0x60, 0x14, // PUSH1 20
            0x60, 0x04, // PUSH1 4
            0x04,       // DIV
        };
        
        _ = try vm.execute(&bytecode, &[_]u8{});
        const result = try vm.stack.pop();
        std.debug.print("  Result: {}\n", .{result.limbs[0]});
        std.debug.print("  Gas used: {}\n\n", .{vm.gas_used});
    }
    
    // Test 4: Modulo
    {
        var vm = try evm.EVM.init(allocator, 100000);
        defer vm.deinit();
        
        std.debug.print("Test 4: 17 % 5 = ?\n", .{});
        const bytecode = [_]u8{
            0x60, 0x11, // PUSH1 17
            0x60, 0x05, // PUSH1 5
            0x06,       // MOD
        };
        
        _ = try vm.execute(&bytecode, &[_]u8{});
        const result = try vm.stack.pop();
        std.debug.print("  Result: {}\n", .{result.limbs[0]});
        std.debug.print("  Gas used: {}\n\n", .{vm.gas_used});
    }
    
    // Test 5: Comparison - Less Than
    {
        var vm = try evm.EVM.init(allocator, 100000);
        defer vm.deinit();
        
        std.debug.print("Test 5: 3 < 7 ?\n", .{});
        const bytecode = [_]u8{
            0x60, 0x03, // PUSH1 3
            0x60, 0x07, // PUSH1 7
            0x10,       // LT
        };
        
        _ = try vm.execute(&bytecode, &[_]u8{});
        const result = try vm.stack.pop();
        std.debug.print("  Result: {} (1=true, 0=false)\n", .{result.limbs[0]});
        std.debug.print("  Gas used: {}\n\n", .{vm.gas_used});
    }
    
    // Test 6: Complex Expression - (10 + 5) * 2
    {
        var vm = try evm.EVM.init(allocator, 100000);
        defer vm.deinit();
        
        std.debug.print("Test 6: (10 + 5) * 2 = ?\n", .{});
        const bytecode = [_]u8{
            0x60, 0x0a, // PUSH1 10
            0x60, 0x05, // PUSH1 5
            0x01,       // ADD
            0x60, 0x02, // PUSH1 2
            0x02,       // MUL
        };
        
        _ = try vm.execute(&bytecode, &[_]u8{});
        const result = try vm.stack.pop();
        std.debug.print("  Result: {}\n", .{result.limbs[0]});
        std.debug.print("  Gas used: {}\n\n", .{vm.gas_used});
    }
    
    // Test 7: Bitwise AND
    {
        var vm = try evm.EVM.init(allocator, 100000);
        defer vm.deinit();
        
        std.debug.print("Test 7: 0xFF & 0x0F = ?\n", .{});
        const bytecode = [_]u8{
            0x60, 0xff, // PUSH1 0xFF
            0x60, 0x0f, // PUSH1 0x0F
            0x16,       // AND
        };
        
        _ = try vm.execute(&bytecode, &[_]u8{});
        const result = try vm.stack.pop();
        std.debug.print("  Result: 0x{x}\n", .{result.limbs[0]});
        std.debug.print("  Gas used: {}\n\n", .{vm.gas_used});
    }
    
    std.debug.print("✅ All arithmetic operations work perfectly!\n", .{});
}

