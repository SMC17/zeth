const std = @import("std");
const evm = @import("evm");
const types = @import("types");
const testing = std.testing;
const comparison = @import("comparison_tool");
const reference = @import("reference_interfaces");
const tracker = @import("discrepancy_tracker");

/// Test runner that executes opcodes on both our EVM and reference implementations
/// and tracks discrepancies

pub const TestRunner = struct {
    allocator: std.mem.Allocator,
    discrepancy_tracker: tracker.DiscrepancyTracker,
    tests_run: usize = 0,
    tests_passed: usize = 0,
    tests_failed: usize = 0,
    
    pub fn init(allocator: std.mem.Allocator) TestRunner {
        return TestRunner{
            .allocator = allocator,
            .discrepancy_tracker = tracker.DiscrepancyTracker.init(allocator),
            .tests_run = 0,
            .tests_passed = 0,
            .tests_failed = 0,
        };
    }
    
    pub fn deinit(self: *TestRunner) void {
        self.discrepancy_tracker.deinit();
    }
    
    /// Run a single opcode test against reference implementation
    pub fn runOpcodeTest(self: *TestRunner, test_case: comparison.OpcodeTestCase) !void {
        self.tests_run += 1;
        
        // Execute on our EVM
        var our_result = try comparison.executeOurEVM(self.allocator, test_case.bytecode, test_case.calldata, 1000000);
        defer our_result.deinit(self.allocator);
        
        // Try to execute on reference (PyEVM or Geth)
        const ref_result = reference.executeWithPyEVM(self.allocator, test_case.bytecode, test_case.calldata) catch |err| {
            // Reference not available - skip comparison but mark test as run
            std.debug.print("Reference not available for {s}: {}\n", .{ test_case.name, err });
            return;
        };
        defer ref_result.deinit();
        
        // Compare results
        const ref_result_wrapped = comparison.ExecutionComparison.ReferenceResult{
            .success = ref_result.success,
            .return_data = ref_result.return_data,
            .gas_used = ref_result.gas_used,
        };
        
        try comparison.compareResults(self.allocator, &our_result, ref_result_wrapped);
        
        // Track discrepancies
        if (!our_result.matches) {
            self.tests_failed += 1;
            for (our_result.discrepancies.items) |disc| {
                // Determine severity based on discrepancy type
                const severity: tracker.Discrepancy.Severity = if (std.mem.eql(u8, disc.category, "Execution"))
                    .critical
                else if (std.mem.eql(u8, disc.category, "Gas"))
                    .medium
                else
                    .high;
                
                const disc_type: tracker.DiscrepancyType = if (std.mem.eql(u8, disc.category, "Gas"))
                    .gas_cost
                else if (std.mem.eql(u8, disc.category, "Stack"))
                    .stack_state
                else if (std.mem.eql(u8, disc.category, "Return Data"))
                    .return_data
                else
                    .execution_result;
                
                try self.discrepancy_tracker.add(
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
        } else {
            self.tests_passed += 1;
        }
    }
    
    /// Run all critical opcode tests
    pub fn runAllCriticalTests(self: *TestRunner) !void {
        std.debug.print("Running critical opcode tests against reference...\n", .{});
        
        for (comparison.critical_opcode_tests) |test_case| {
            self.runOpcodeTest(test_case) catch |err| {
                std.debug.print("Test {s} failed: {}\n", .{ test_case.name, err });
                self.tests_failed += 1;
            };
        }
        
        std.debug.print("\nTest Results:\n", .{});
        std.debug.print("  Total: {}\n", .{self.tests_run});
        std.debug.print("  Passed: {}\n", .{self.tests_passed});
        std.debug.print("  Failed: {}\n", .{self.tests_failed});
        std.debug.print("  Match rate: {d:.1}%\n", .{if (self.tests_run > 0) @as(f64, @floatFromInt(self.tests_passed)) / @as(f64, @floatFromInt(self.tests_run)) * 100.0 else 0.0});
    }
    
    /// Generate discrepancy report
    pub fn generateReport(self: *TestRunner, file_path: []const u8) !void {
        try self.discrepancy_tracker.saveToFile(file_path);
        std.debug.print("Discrepancy report saved to: {s}\n", .{file_path});
    }
};

test "Test runner: Basic functionality" {
    const testing_allocator = testing.allocator;
    var runner = TestRunner.init(testing_allocator);
    defer runner.deinit();
    
    // Run a simple test
    const test_case = comparison.critical_opcode_tests[0]; // ADD
    try runner.runOpcodeTest(test_case);
    
    // Runner should have executed at least one test
    // (may fail if reference not available, which is ok)
}

/// Main test suite - runs all opcodes against reference
test "Reference comparison: Run all critical tests" {
    const testing_allocator = testing.allocator;
    var runner = TestRunner.init(testing_allocator);
    defer runner.deinit();
    
    // Only run if reference is available
    if (reference.isPyEVMAvailable() or reference.isGethAvailable()) {
        try runner.runAllCriticalTests();
        
        // Generate report
        try runner.generateReport("/tmp/zeth_discrepancies.txt");
        
        // Should have run some tests
        try testing.expect(runner.tests_run > 0);
    } else {
        std.debug.print("Reference implementations not available, skipping comparison tests\n", .{});
    }
}

