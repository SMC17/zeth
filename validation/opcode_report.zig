const std = @import("std");
const comparison = @import("comparison_tool");
const reference = @import("reference_interfaces");
const types = @import("types");

const TestEntry = struct {
    name: []const u8,
    group: []const u8,
    precompile_id: ?u8,
    description: []const u8,
    pass: bool,
    gas_used: u64,
    expected_gas: ?u64,
    gas_delta: ?i64,
    compared_with_reference: bool,
    reference_match: bool,
    reference_gas: ?u64,
    reference_gas_delta: ?i64,
};

const Summary = struct {
    total: usize,
    passed: usize,
    failed: usize,
    precompile_total: usize,
    precompile_passed: usize,
    precompile_failed: usize,
    reference_available: bool,
    reference_compared: usize,
    reference_mismatches: usize,
};

const Report = struct {
    generated_at_unix: i64,
    summary: Summary,
    tests: []TestEntry,
};

fn gasDelta(actual: u64, expected: ?u64) ?i64 {
    if (expected) |exp| {
        return @as(i64, @intCast(actual)) - @as(i64, @intCast(exp));
    }
    return null;
}

fn parseOutPath(args: []const []const u8) ?[]const u8 {
    var i: usize = 1;
    while (i + 1 < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--out")) {
            return args[i + 1];
        }
    }
    return null;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);
    const out_path = parseOutPath(argv);

    const pyevm_available = reference.isPyEVMAvailable();
    const geth_available = reference.isGethAvailable();
    const reference_available = pyevm_available or geth_available;

    var entries = std.ArrayList(TestEntry).init(allocator);
    defer entries.deinit();

    var passed: usize = 0;
    var failed: usize = 0;
    var precompile_total: usize = 0;
    var precompile_passed: usize = 0;
    var precompile_failed: usize = 0;
    var ref_compared: usize = 0;
    var ref_mismatches: usize = 0;

    for (comparison.differential_test_cases) |tc| {
        var pass = true;
        var compared_ref = false;
        var ref_match = true;
        var ref_gas: ?u64 = null;
        var ref_gas_delta: ?i64 = null;

        const prepared = try comparison.prepareOpcodeCase(allocator, tc);
        defer prepared.deinit(allocator);

        var our = try comparison.executeOurEVM(allocator, prepared.code, prepared.calldata, 1_000_000);
        defer our.deinit(allocator);

        if (our.our_error != null) {
            pass = false;
        } else {
            if (tc.expected_return_data) |expected_return| {
                if (!std.mem.eql(u8, our.our_result.return_data, expected_return)) {
                    pass = false;
                }
            }
            if (tc.expected_stack_top) |expected_top| {
                if (our.our_stack.len == 0 or !our.our_stack[0].eq(expected_top)) {
                    pass = false;
                }
            }
        }

        if (pyevm_available) {
            var ref_result = reference.executeWithPyEVM(allocator, prepared.code, prepared.calldata) catch null;
            if (ref_result) |*rr| {
                defer rr.deinit();
                compared_ref = true;
                ref_compared += 1;
                ref_gas = rr.gas_used;
                ref_gas_delta = @as(i64, @intCast(our.our_gas)) - @as(i64, @intCast(rr.gas_used));
                if (our.our_error != null) {
                    ref_match = false;
                } else {
                    ref_match = our.our_result.success == rr.success and
                        std.mem.eql(u8, our.our_result.return_data, rr.return_data);
                }
                if (!ref_match) {
                    ref_mismatches += 1;
                }
            }
        }

        if (pass) passed += 1 else failed += 1;
        if (std.mem.eql(u8, tc.group, "precompile")) {
            precompile_total += 1;
            if (pass) precompile_passed += 1 else precompile_failed += 1;
        }

        try entries.append(.{
            .name = tc.name,
            .group = tc.group,
            .precompile_id = tc.precompile_id,
            .description = tc.description,
            .pass = pass,
            .gas_used = our.our_gas,
            .expected_gas = tc.expected_gas,
            .gas_delta = gasDelta(our.our_gas, tc.expected_gas),
            .compared_with_reference = compared_ref,
            .reference_match = ref_match,
            .reference_gas = ref_gas,
            .reference_gas_delta = ref_gas_delta,
        });
    }

    const report = Report{
        .generated_at_unix = std.time.timestamp(),
        .summary = .{
            .total = entries.items.len,
            .passed = passed,
            .failed = failed,
            .precompile_total = precompile_total,
            .precompile_passed = precompile_passed,
            .precompile_failed = precompile_failed,
            .reference_available = reference_available,
            .reference_compared = ref_compared,
            .reference_mismatches = ref_mismatches,
        },
        .tests = entries.items,
    };

    if (out_path) |path| {
        const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        try std.json.stringify(report, .{ .whitespace = .indent_2 }, file.writer());
        try file.writer().writeByte('\n');
    } else {
        const stdout = std.io.getStdOut().writer();
        try std.json.stringify(report, .{ .whitespace = .indent_2 }, stdout);
        try stdout.writeByte('\n');
    }
}
