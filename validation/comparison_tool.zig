const std = @import("std");
const evm = @import("evm");
const types = @import("types");
const testing = std.testing;

/// Comparison tool for testing our EVM against reference implementations
/// This tool executes bytecode and compares results

pub const ExecutionComparison = struct {
    our_result: evm.ExecutionResult,
    our_stack: []types.U256,
    our_memory: []u8,
    our_storage: std.ArrayList(StorageEntry),
    our_gas: u64,
    our_error: ?anyerror,
    
    reference_result: ?ReferenceResult = null,
    reference_gas: ?u64 = null,
    reference_error: ?[]const u8 = null,
    
    matches: bool = false,
    discrepancies: std.ArrayList(Discrepancy),
    
    const StorageEntry = struct {
        key: types.U256,
        value: types.U256,
    };
    
    pub const ReferenceResult = struct {
        success: bool,
        return_data: []const u8,
        gas_used: u64,
    };
    
    const Discrepancy = struct {
        category: []const u8,
        description: []const u8,
        our_value: []const u8,
        reference_value: []const u8,
    };
    
    pub fn init(allocator: std.mem.Allocator) !ExecutionComparison {
        return ExecutionComparison{
            .our_result = undefined,
            .our_stack = &[_]types.U256{},
            .our_memory = &[_]u8{},
            .our_storage = try std.ArrayList(StorageEntry).initCapacity(allocator, 0),
            .our_gas = 0,
            .our_error = null,
            .discrepancies = try std.ArrayList(Discrepancy).initCapacity(allocator, 0),
        };
    }
    
    pub fn deinit(self: *ExecutionComparison, allocator: std.mem.Allocator) void {
        allocator.free(self.our_stack);
        allocator.free(self.our_memory);
        self.our_storage.deinit(allocator);
        self.discrepancies.deinit(allocator);
    }
    
    pub fn addDiscrepancy(self: *ExecutionComparison, category: []const u8, description: []const u8, our_val: []const u8, ref_val: []const u8, allocator: std.mem.Allocator) !void {
        try self.discrepancies.append(allocator, Discrepancy{
            .category = category,
            .description = description,
            .our_value = our_val,
            .reference_value = ref_val,
        });
        self.matches = false;
    }
    
    pub fn format(self: ExecutionComparison, writer: anytype) !void {
        try writer.print("Execution Comparison:\n", .{});
        try writer.print("  Gas: Our={}, Reference={}\n", .{ self.our_gas, self.reference_gas orelse 0 });
        try writer.print("  Matches: {}\n", .{self.matches});
        
        if (self.discrepancies.items.len > 0) {
            try writer.print("  Discrepancies ({d}):\n", .{self.discrepancies.items.len});
            for (self.discrepancies.items) |disc| {
                try writer.print("    [{s}] {s}\n", .{ disc.category, disc.description });
                try writer.print("      Our: {s}\n", .{disc.our_value});
                try writer.print("      Ref: {s}\n", .{disc.reference_value});
            }
        }
    }
};

/// Execute bytecode on our EVM and capture full state
pub fn executeOurEVM(allocator: std.mem.Allocator, code: []const u8, calldata: []const u8, gas_limit: u64) !ExecutionComparison {
    var comparison = try ExecutionComparison.init(allocator);
    errdefer comparison.deinit(allocator);
    
    var vm = try evm.EVM.init(allocator, gas_limit);
    defer vm.deinit();
    
    const result = vm.execute(code, calldata) catch |err| {
        comparison.our_error = err;
        comparison.our_gas = vm.gas_used;
        return comparison;
    };
    
    comparison.our_result = result;
    comparison.our_gas = result.gas_used;
    
    // Capture stack state
    var stack = try std.ArrayList(types.U256).initCapacity(allocator, vm.stack.items.items.len);
    defer stack.deinit(allocator);
    while (vm.stack.items.items.len > 0) {
        const value = vm.stack.pop() catch break;
        try stack.append(allocator, value);
    }
    comparison.our_stack = try stack.toOwnedSlice(allocator);
    
    // Capture memory state (only copy used memory)
    comparison.our_memory = try allocator.dupe(u8, vm.memory.data.items);
    
    // Capture storage state (simplified - would need to iterate storage map)
    // For now, we'll capture this during execution tracking
    
    return comparison;
}

/// Format bytecode for display
pub fn formatBytecode(code: []const u8) ![]const u8 {
    const allocator = std.heap.page_allocator;
    var result = try std.ArrayList(u8).initCapacity(allocator, code.len * 3);
    defer result.deinit(allocator);
    
    for (code) |byte| {
        var writer = result.writer(allocator);
        try writer.print("{x:02} ", .{byte});
    }
    
    return try result.toOwnedSlice(allocator);
}

/// Compare two execution results
pub fn compareResults(allocator: std.mem.Allocator, our: *ExecutionComparison, reference: ExecutionComparison.ReferenceResult) !void {
    // Compare gas (allow small variance)
    const gas_diff = if (our.our_gas > reference.gas_used) our.our_gas - reference.gas_used else reference.gas_used - our.our_gas;
    if (gas_diff > 100) { // Allow 100 gas variance for now
        const our_str = try std.fmt.allocPrint(allocator, "{}", .{our.our_gas});
        defer allocator.free(our_str);
        const ref_str = try std.fmt.allocPrint(allocator, "{}", .{reference.gas_used});
        defer allocator.free(ref_str);
        try our.addDiscrepancy("Gas", "Gas consumption differs significantly", our_str, ref_str, allocator);
    }
    
    // Compare success
    if (our.our_result.success != reference.success) {
        const our_str = if (our.our_result.success) "success" else "failure";
        const ref_str = if (reference.success) "success" else "failure";
        try our.addDiscrepancy("Execution", "Success status differs", our_str, ref_str, allocator);
        our.matches = false;
    }
    
    // Compare return data
    if (!std.mem.eql(u8, our.our_result.return_data, reference.return_data)) {
        const our_hex = try formatHex(allocator, our.our_result.return_data);
        defer allocator.free(our_hex);
        const ref_hex = try formatHex(allocator, reference.return_data);
        defer allocator.free(ref_hex);
        try our.addDiscrepancy("Return Data", "Return data differs", our_hex, ref_hex, allocator);
    }
    
    our.reference_result = reference;
    our.reference_gas = reference.gas_used;
    
    // If no discrepancies, mark as matching
    our.matches = (our.discrepancies.items.len == 0);
}

/// Format bytes as hex string
fn formatHex(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, bytes.len * 2 + 2);
    defer result.deinit(allocator);
    
    var writer = result.writer(allocator);
    try writer.print("0x", .{});
    for (bytes) |byte| {
        try writer.print("{x:02}", .{byte});
    }
    
    return try result.toOwnedSlice(allocator);
}

/// Test suite for critical opcodes
pub const OpcodeTestCase = struct {
    name: []const u8,
    bytecode: []const u8,
    calldata: []const u8,
    expected_gas: ?u64 = null,
    expected_stack_top: ?types.U256 = null,
    description: []const u8,
};

/// Critical opcode test cases
pub const critical_opcode_tests = [_]OpcodeTestCase{
    // Arithmetic
    .{
        .name = "ADD",
        .bytecode = &[_]u8{ 0x60, 0x05, 0x60, 0x03, 0x01 }, // PUSH1 5, PUSH1 3, ADD
        .calldata = &[_]u8{},
        .expected_gas = 9, // 3 + 3 + 3
        .expected_stack_top = types.U256.fromU64(8),
        .description = "Simple addition",
    },
    .{
        .name = "MUL",
        .bytecode = &[_]u8{ 0x60, 0x04, 0x60, 0x07, 0x02 }, // PUSH1 4, PUSH1 7, MUL
        .calldata = &[_]u8{},
        .expected_gas = 11, // 3 + 3 + 5
        .expected_stack_top = types.U256.fromU64(28),
        .description = "Simple multiplication",
    },
    .{
        .name = "DIV",
        .bytecode = &[_]u8{ 0x60, 0x0a, 0x60, 0x02, 0x04 }, // PUSH1 10, PUSH1 2, DIV
        .calldata = &[_]u8{},
        .expected_gas = 11, // 3 + 3 + 5
        .expected_stack_top = types.U256.fromU64(5),
        .description = "Simple division",
    },
    .{
        .name = "MOD",
        .bytecode = &[_]u8{ 0x60, 0x0a, 0x60, 0x03, 0x06 }, // PUSH1 10, PUSH1 3, MOD
        .calldata = &[_]u8{},
        .expected_gas = 11, // 3 + 3 + 5
        .expected_stack_top = types.U256.fromU64(1),
        .description = "Simple modulo",
    },
    
    // Storage
    .{
        .name = "SSTORE (cold set)",
        .bytecode = &[_]u8{ 0x60, 0x01, 0x60, 0x2a, 0x55 }, // PUSH1 1, PUSH1 42, SSTORE
        .calldata = &[_]u8{},
        .expected_gas = 20000, // Cold storage set
        .description = "Store to cold storage slot",
    },
    .{
        .name = "SLOAD (cold)",
        .bytecode = &[_]u8{ 0x60, 0x01, 0x54 }, // PUSH1 1, SLOAD
        .calldata = &[_]u8{},
        .expected_gas = 2103, // PUSH1(3) + SLOAD cold(2100)
        .description = "Load from cold storage slot",
    },
    
    // Memory
    .{
        .name = "MSTORE",
        .bytecode = &[_]u8{ 0x60, 0x42, 0x60, 0x00, 0x52 }, // PUSH1 0x42, PUSH1 0, MSTORE
        .calldata = &[_]u8{},
        .expected_gas = 9, // PUSH1(3) + PUSH1(3) + MSTORE(3) + memory expansion
        .description = "Store to memory",
    },
    .{
        .name = "MLOAD",
        .bytecode = &[_]u8{ 0x60, 0x00, 0x51 }, // PUSH1 0, MLOAD
        .calldata = &[_]u8{},
        .expected_gas = 6, // PUSH1(3) + MLOAD(3) + memory expansion
        .description = "Load from memory",
    },
    
    // Comparison
    .{
        .name = "LT",
        .bytecode = &[_]u8{ 0x60, 0x05, 0x60, 0x03, 0x10 }, // PUSH1 5, PUSH1 3, LT
        .calldata = &[_]u8{},
        .expected_gas = 9, // 3 + 3 + 3
        .expected_stack_top = types.U256.zero(), // 5 < 3 is false
        .description = "Less than comparison",
    },
    .{
        .name = "GT",
        .bytecode = &[_]u8{ 0x60, 0x05, 0x60, 0x03, 0x11 }, // PUSH1 5, PUSH1 3, GT
        .calldata = &[_]u8{},
        .expected_gas = 9,
        .expected_stack_top = types.U256.one(), // 5 > 3 is true
        .description = "Greater than comparison",
    },
    .{
        .name = "EQ",
        .bytecode = &[_]u8{ 0x60, 0x05, 0x60, 0x05, 0x14 }, // PUSH1 5, PUSH1 5, EQ
        .calldata = &[_]u8{},
        .expected_gas = 9,
        .expected_stack_top = types.U256.one(), // 5 == 5 is true
        .description = "Equality comparison",
    },
};

/// Run test case and verify
pub fn runTestCase(allocator: std.mem.Allocator, test_case: OpcodeTestCase) !ExecutionComparison {
    var comparison = try executeOurEVM(allocator, test_case.bytecode, test_case.calldata, 1000000);
    
    // Verify expected values if provided
    if (test_case.expected_stack_top) |expected| {
        if (comparison.our_stack.len > 0) {
            const actual = comparison.our_stack[0];
            if (!actual.eq(expected)) {
                const actual_str = try std.fmt.allocPrint(allocator, "{}", .{actual.limbs[0]});
                defer allocator.free(actual_str);
                const expected_str = try std.fmt.allocPrint(allocator, "{}", .{expected.limbs[0]});
                defer allocator.free(expected_str);
                try comparison.addDiscrepancy("Stack", "Stack top value differs", actual_str, expected_str, allocator);
            }
        }
    }
    
    if (test_case.expected_gas) |expected_gas| {
        if (comparison.our_gas != expected_gas) {
            const actual_str = try std.fmt.allocPrint(allocator, "{}", .{comparison.our_gas});
            defer allocator.free(actual_str);
            const expected_str = try std.fmt.allocPrint(allocator, "{}", .{expected_gas});
            defer allocator.free(expected_str);
            try comparison.addDiscrepancy("Gas", "Gas cost differs", actual_str, expected_str, allocator);
        }
    }
    
    return comparison;
}

test "Comparison tool: Basic execution" {
    const test_case = critical_opcode_tests[0]; // ADD
    var comparison = try runTestCase(testing.allocator, test_case);
    defer comparison.deinit(testing.allocator);
    
    try testing.expect(comparison.our_result.success);
    try testing.expect(comparison.our_gas > 0);
    try testing.expect(comparison.our_stack.len > 0);
}

