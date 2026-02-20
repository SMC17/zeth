//! Differential fuzzing harness: run same tx through Zeth and PyEVM, compare outputs.
//! On mismatch, emit structured report for triage.
//!
//! Usage:
//!   zig build run-differential-fuzz -- <iterations>
//!   zig build run-differential-fuzz -- 1000
//!
//! Requires PyEVM: pip3 install eth-py-evm

const std = @import("std");
const evm = @import("evm");
const types = @import("types");
const comparison = @import("comparison_tool");
const reference = @import("reference_interfaces");

const DEFAULT_ITERATIONS = 100;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var iterations: u32 = DEFAULT_ITERATIONS;
    var fail_on_mismatch: bool = true;
    var args = std.process.args();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--no-fail")) {
            fail_on_mismatch = false;
        } else if (std.fmt.parseInt(u32, arg, 10)) |n| {
            iterations = n;
        } else |_| {}
    }

    const ref_available = blk: {
        var code: [3]u8 = .{ 0x60, 0x01, 0x00 }; // PUSH1 1, STOP
        var result = reference.executeWithPyEVM(allocator, &code, &[_]u8{}) catch break :blk false;
        result.deinit();
        break :blk true;
    };

    if (!ref_available) {
        std.debug.print("PyEVM not available. Install: pip3 install eth-py-evm\n", .{});
        std.process.exit(1);
    }

    var rng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));
    var mismatches: u32 = 0;
    var total: u32 = 0;

    std.debug.print("Running {} differential iterations...\n", .{iterations});

    for (0..iterations) |_| {
        const code = try randomBytecode(allocator, rng.random(), 4, 32);
        defer allocator.free(code);
        const calldata = try randomBytes(allocator, rng.random(), 0, 64);
        defer allocator.free(calldata);

        var our = comparison.executeOurEVM(allocator, code, calldata, 10_000_000) catch continue;
        defer our.deinit(allocator);

        var ref_result = reference.executeWithPyEVM(allocator, code, calldata) catch continue;
        defer ref_result.deinit();

        const ref_wrapped = comparison.ExecutionComparison.ReferenceResult{
            .success = ref_result.success,
            .return_data = ref_result.return_data,
            .gas_used = ref_result.gas_used,
        };

        try comparison.compareResults(allocator, &our, ref_wrapped);
        total += 1;

        if (!our.matches) {
            mismatches += 1;
            std.debug.print("\n--- MISMATCH #{d} ---\n", .{mismatches});
            std.debug.print("code: 0x", .{});
            for (code) |b| std.debug.print("{x:0>2}", .{b});
            std.debug.print("\ncalldata: 0x", .{});
            for (calldata) |b| std.debug.print("{x:0>2}", .{b});
            std.debug.print("\n", .{});
            try our.format(std.io.getStdErr().writer());
        }
    }

    std.debug.print("\nDifferential fuzz: {} / {} matched\n", .{ total - mismatches, total });
    if (mismatches > 0 and fail_on_mismatch) {
        std.process.exit(1);
    }
}

fn randomBytes(allocator: std.mem.Allocator, rng: std.Random, min_len: usize, max_len: usize) ![]u8 {
    const len = rng.intRangeAtMost(usize, min_len, max_len);
    const buf = try allocator.alloc(u8, len);
    for (buf) |*b| b.* = rng.int(u8);
    return buf;
}

fn randomBytecode(allocator: std.mem.Allocator, rng: std.Random, min_len: usize, max_len: usize) ![]u8 {
    const len = rng.intRangeAtMost(usize, min_len, max_len);
    const buf = try allocator.alloc(u8, len);
    for (buf) |*b| b.* = rng.int(u8);
    return buf;
}
