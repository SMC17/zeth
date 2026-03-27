const std = @import("std");
const evm = @import("evm");
const types = @import("types");
const comparison = @import("comparison_tool");
const reference = @import("reference_interfaces");
const tracker = @import("discrepancy_tracker");
const test_runner_mod = @import("reference_test_runner");

/// Standalone executable to run reference comparison tests
/// Usage: zig run validation/run_reference_tests.zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var discrepancy_txt_path: []const u8 = "/tmp/zeth_discrepancies.txt";
    var discrepancy_json_path: []const u8 = "/tmp/zeth_discrepancies.json";
    var summary_json_path: ?[]const u8 = null;
    var require_reference = false;
    var baseline_json_path: ?[]const u8 = null;
    var fail_on_regression = false;

    var args = std.process.args();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--discrepancy-out")) {
            if (args.next()) |p| discrepancy_txt_path = p;
        } else if (std.mem.eql(u8, arg, "--discrepancy-json")) {
            if (args.next()) |p| discrepancy_json_path = p;
        } else if (std.mem.eql(u8, arg, "--summary-json")) {
            if (args.next()) |p| summary_json_path = p;
        } else if (std.mem.eql(u8, arg, "--require-reference")) {
            require_reference = true;
        } else if (std.mem.eql(u8, arg, "--baseline-json")) {
            if (args.next()) |p| baseline_json_path = p;
        } else if (std.mem.eql(u8, arg, "--fail-on-regression")) {
            fail_on_regression = true;
        }
    }

    std.debug.print("Zeth Reference Comparison Test Runner\n", .{});
    std.debug.print("=====================================\n\n", .{});

    // Check reference availability
    const pyevm_available = reference.isPyEVMAvailable();
    const geth_available = reference.isGethAvailable();

    std.debug.print("Reference Implementations:\n", .{});
    std.debug.print("  PyEVM: {}\n", .{pyevm_available});
    std.debug.print("  Geth:  {}\n", .{geth_available});
    std.debug.print("\n", .{});

    if (!pyevm_available and !geth_available) {
        std.debug.print("WARNING: No reference implementations available!\n", .{});
        std.debug.print("Please install PyEVM: pip3 install eth-py-evm\n", .{});
        std.debug.print("See validation/SETUP_PYEVM.md for instructions.\n", .{});
        std.debug.print("\n", .{});
        std.debug.print("Running tests without reference comparison...\n\n", .{});
    }

    // Run tests
    var test_runner = try test_runner_mod.TestRunner.init(allocator);
    defer test_runner.deinit();

    std.debug.print("Running critical opcode tests...\n", .{});

    var tests_run: usize = 0;
    var tests_passed: usize = 0;

    for (comparison.differential_test_cases) |test_case| {
        tests_run += 1;
        std.debug.print("  Testing {s}... ", .{test_case.name});

        const prepared = try comparison.prepareOpcodeCase(allocator, test_case);
        defer prepared.deinit(allocator);

        // Execute on our EVM
        var our_result = try comparison.executeOurEVMWithPrestate(
            allocator,
            prepared.code,
            prepared.calldata,
            1000000,
            test_case.pre_storage,
            test_case.tracked_storage,
        );
        defer our_result.deinit(allocator);

        // Try reference if available
        if (pyevm_available) {
            var ref_result = reference.executeWithPyEVM(
                allocator,
                prepared.code,
                prepared.calldata,
                test_case.pre_storage,
                test_case.tracked_storage,
            ) catch |err| {
                std.debug.print("ERROR (reference failed: {})\n", .{err});
                continue;
            };
            defer ref_result.deinit();

            // Debug: Print what we got from PyEVM
            std.debug.print("  [DEBUG] PyEVM: success={}, gas={}, error={s}\n", .{ ref_result.success, ref_result.gas_used, ref_result.error_message orelse "none" });
            std.debug.print("  [DEBUG] Our EVM: success={}, gas={}\n", .{ our_result.our_result.success, our_result.our_gas });

            // Compare
            const ref_wrapped = comparison.ExecutionComparison.ReferenceResult{
                .success = ref_result.success,
                .return_data = ref_result.return_data,
                .gas_used = ref_result.gas_used,
                .stack = ref_result.stack,
                .storage = ref_result.storage,
            };

            try comparison.compareResults(allocator, &our_result, ref_wrapped);

            if (our_result.matches) {
                std.debug.print("PASS\n", .{});
                tests_passed += 1;
            } else {
                std.debug.print("FAIL ({d} discrepancies)\n", .{our_result.discrepancies.items.len});
                // Track discrepancies
                for (our_result.discrepancies.items) |disc| {
                    const severity: tracker.Discrepancy.Severity = if (std.mem.eql(u8, disc.category, "Execution")) .critical else .medium;
                    const disc_type: tracker.DiscrepancyType = if (std.mem.eql(u8, disc.category, "Gas")) .gas_cost else .execution_result;
                    try test_runner.discrepancy_tracker.add(
                        test_case.name,
                        disc_type,
                        disc.description,
                        disc.our_value,
                        disc.reference_value,
                        prepared.code,
                        prepared.calldata,
                        severity,
                    );
                }
            }
        } else {
            // No reference - just verify our implementation works
            if (our_result.our_result.success) {
                std.debug.print("PASS (no reference)\n", .{});
                tests_passed += 1;
            } else {
                std.debug.print("FAIL\n", .{});
            }
        }
    }

    std.debug.print("\n", .{});
    std.debug.print("Test Results:\n", .{});
    std.debug.print("  Total: {}\n", .{tests_run});
    std.debug.print("  Passed: {}\n", .{tests_passed});
    std.debug.print("  Failed: {}\n", .{tests_run - tests_passed});
    if (tests_run > 0) {
        const match_rate = (@as(f64, @floatFromInt(tests_passed)) / @as(f64, @floatFromInt(tests_run))) * 100.0;
        std.debug.print("  Match Rate: {d:.1}%\n", .{match_rate});
    }

    // Generate discrepancy report
    if (test_runner.discrepancy_tracker.count() > 0) {
        std.debug.print("\n", .{});
        std.debug.print("Discrepancies found: {}\n", .{test_runner.discrepancy_tracker.count()});
        try test_runner.discrepancy_tracker.saveToFile(discrepancy_txt_path);
        try test_runner.discrepancy_tracker.saveJsonToFile(discrepancy_json_path);
        std.debug.print("Report saved to: {s}\n", .{discrepancy_txt_path});
        std.debug.print("JSON report saved to: {s}\n", .{discrepancy_json_path});
    } else {
        std.debug.print("\n", .{});
        std.debug.print("No discrepancies found!\n", .{});
        var empty_tracker = try tracker.DiscrepancyTracker.init(allocator);
        defer empty_tracker.deinit();
        try empty_tracker.saveToFile(discrepancy_txt_path);
        try empty_tracker.saveJsonToFile(discrepancy_json_path);
    }

    if (summary_json_path) |path| {
        const summary = .{
            .tests_run = tests_run,
            .tests_passed = tests_passed,
            .tests_failed = tests_run - tests_passed,
            .reference_available = pyevm_available or geth_available,
            .pyevm_available = pyevm_available,
            .geth_available = geth_available,
            .discrepancy_count = test_runner.discrepancy_tracker.count(),
            .generated_at = std.time.timestamp(),
        };
        const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        try std.json.stringify(summary, .{ .whitespace = .indent_2 }, file.writer());
    }

    if (fail_on_regression) {
        if (baseline_json_path == null) return error.MissingBaseline;
        try enforceDiscrepancyBaseline(allocator, baseline_json_path.?, &test_runner.discrepancy_tracker);
    }

    // Strict gate: if reference implementation is available, any mismatch fails.
    if (pyevm_available or geth_available) {
        if (tests_passed != tests_run or test_runner.discrepancy_tracker.count() > 0) {
            return error.ReferenceMismatch;
        }
    } else if (require_reference) {
        return error.ReferenceUnavailable;
    }
}

fn buildDiscrepancyKey(allocator: std.mem.Allocator, opcode: []const u8, disc_type: []const u8, description: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}|{s}|{s}", .{ opcode, disc_type, description });
}

fn enforceDiscrepancyBaseline(allocator: std.mem.Allocator, baseline_path: []const u8, current: *const tracker.DiscrepancyTracker) !void {
    const content = try std.fs.cwd().readFileAlloc(allocator, baseline_path, 4 * 1024 * 1024);
    defer allocator.free(content);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const summary = root.get("summary") orelse return error.InvalidBaseline;
    const baseline_total: usize = @intCast(summary.object.get("total").?.integer);

    var baseline_keys = std.StringHashMap(void).init(allocator);
    defer {
        var it = baseline_keys.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        baseline_keys.deinit();
    }

    if (root.get("discrepancies")) |discrepancies_val| {
        for (discrepancies_val.array.items) |disc_val| {
            const disc = disc_val.object;
            const key = try buildDiscrepancyKey(
                allocator,
                disc.get("opcode").?.string,
                disc.get("type").?.string,
                disc.get("description").?.string,
            );
            try baseline_keys.put(key, {});
        }
    }

    if (current.count() > baseline_total) return error.DiscrepancyRegression;

    for (current.discrepancies.items) |disc| {
        const key = try buildDiscrepancyKey(allocator, disc.opcode, @tagName(disc.type), disc.description);
        defer allocator.free(key);
        if (!baseline_keys.contains(key)) return error.DiscrepancyRegression;
    }
}
