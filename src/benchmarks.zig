const std = @import("std");
const evm = @import("evm");
const types = @import("types");
const crypto = @import("crypto");

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
        
        // Use result to prevent optimization
        if (result.isZero()) unreachable;
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
            0x01,       // ADD
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
    
    std.debug.print("=== Benchmarks Complete ===\n", .{});
    std.debug.print("\nNote: These are unoptimized. Plenty of room for improvement.\n", .{});
}
