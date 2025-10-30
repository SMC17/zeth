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
    
    for (comparison.critical_opcode_tests) |test_case| {
        tests_run += 1;
        std.debug.print("  Testing {s}... ", .{test_case.name});
        
        // Execute on our EVM
        var our_result = try comparison.executeOurEVM(allocator, test_case.bytecode, test_case.calldata, 1000000);
        defer our_result.deinit(allocator);
        
        // Try reference if available
        if (pyevm_available) {
            var ref_result = reference.executeWithPyEVM(allocator, test_case.bytecode, test_case.calldata) catch |err| {
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
                        test_case.bytecode,
                        test_case.calldata,
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
        try test_runner.discrepancy_tracker.saveToFile("/tmp/zeth_discrepancies.txt");
        std.debug.print("Report saved to: /tmp/zeth_discrepancies.txt\n", .{});
    } else {
        std.debug.print("\n", .{});
        std.debug.print("No discrepancies found!\n", .{});
    }
}

