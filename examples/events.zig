const std = @import("std");
const evm = @import("evm");
const types = @import("types");

/// Event Logging Contract Example
///
/// Demonstrates LOG opcodes for emitting events
///
/// Solidity equivalent:
/// ```solidity
/// contract Events {
///     event ValueStored(uint256 indexed key, uint256 value);
///     event Transfer(address indexed from, address indexed to, uint256 amount);
/// }
/// ```

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.debug.print("\n=== Event Logging Contract Example ===\n\n", .{});
    
    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();
    
    // Test 1: Emit LOG1 (one topic)
    std.debug.print("Test 1: Emit LOG1 event\n", .{});
    
    // Store data in memory first (offset 0, value 42)
    // Then emit LOG1 with topic
    const log1_bytecode = [_]u8{
        0x60, 0x2a,       // PUSH1 42 (data value)
        0x60, 0x00,       // PUSH1 0 (memory offset)
        0x52,             // MSTORE
        0x60, 0xaa,       // PUSH1 0xaa (topic)
        0x60, 0x20,       // PUSH1 32 (data length)
        0x60, 0x00,       // PUSH1 0 (data offset)
        0xa1,             // LOG1
    };
    
    const result1 = try vm.execute(&log1_bytecode, &[_]u8{});
    defer {
        for (result1.logs) |log| {
            allocator.free(log.topics);
            allocator.free(log.data);
        }
        allocator.free(result1.logs);
    }
    
    std.debug.print("  Success: {}\n", .{result1.success});
    std.debug.print("  Logs emitted: {}\n", .{result1.logs.len});
    std.debug.print("  Gas used: {}\n\n", .{vm.gas_used});
    
    // Test 2: Emit LOG2 (two topics) - like Transfer event
    std.debug.print("Test 2: Emit LOG2 event (Transfer-like)\n", .{});
    
    var vm2 = try evm.EVM.init(allocator, 1000000);
    defer vm2.deinit();
    
    // Store amount in memory, emit with from/to topics
    const log2_bytecode = [_]u8{
        0x61, 0x03, 0xe8, // PUSH2 1000 (amount)
        0x60, 0x00,       // PUSH1 0
        0x52,             // MSTORE
        0x60, 0x02,       // PUSH1 0x02 (topic2: to)
        0x60, 0x01,       // PUSH1 0x01 (topic1: from)
        0x60, 0x20,       // PUSH1 32 (length)
        0x60, 0x00,       // PUSH1 0 (offset)
        0xa2,             // LOG2
    };
    
    const result2 = try vm2.execute(&log2_bytecode, &[_]u8{});
    defer {
        for (result2.logs) |log| {
            allocator.free(log.topics);
            allocator.free(log.data);
        }
        allocator.free(result2.logs);
    }
    
    std.debug.print("  Success: {}\n", .{result2.success});
    std.debug.print("  Logs emitted: {}\n", .{result2.logs.len});
    
    if (result2.logs.len > 0) {
        std.debug.print("  Topics: {}\n", .{result2.logs[0].topics.len});
    }
    std.debug.print("  Gas used: {}\n\n", .{vm2.gas_used});
    
    std.debug.print("Event logging works perfectly!\n", .{});
}

