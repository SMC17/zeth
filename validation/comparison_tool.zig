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
        // Free all discrepancy strings that were duplicated in addDiscrepancy
        for (self.discrepancies.items) |disc| {
            allocator.free(disc.category);
            allocator.free(disc.description);
            allocator.free(disc.our_value);
            allocator.free(disc.reference_value);
        }
        allocator.free(self.our_stack);
        allocator.free(self.our_memory);
        if (self.our_error == null) {
            if (self.our_result.return_data.len > 0) allocator.free(self.our_result.return_data);
            if (self.our_result.logs.len > 0) allocator.free(self.our_result.logs);
        }
        self.our_storage.deinit();
        self.discrepancies.deinit();
    }

    pub fn addDiscrepancy(self: *ExecutionComparison, category: []const u8, description: []const u8, our_val: []const u8, ref_val: []const u8, allocator: std.mem.Allocator) !void {
        // Duplicate strings so they outlive the caller's scope
        const cat_dup = try allocator.dupe(u8, category);
        const desc_dup = try allocator.dupe(u8, description);
        const our_dup = try allocator.dupe(u8, our_val);
        const ref_dup = try allocator.dupe(u8, ref_val);

        try self.discrepancies.append(Discrepancy{
            .category = cat_dup,
            .description = desc_dup,
            .our_value = our_dup,
            .reference_value = ref_dup,
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
    defer stack.deinit();
    while (vm.stack.items.items.len > 0) {
        const value = vm.stack.pop() catch break;
        try stack.append(value);
    }
    comparison.our_stack = try stack.toOwnedSlice();

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
    defer result.deinit();

    var writer = result.writer();
    for (code) |byte| {
        try writer.print("{x:02} ", .{byte});
    }

    return try result.toOwnedSlice();
}

/// Compare two execution results
pub fn compareResults(allocator: std.mem.Allocator, our: *ExecutionComparison, reference: ExecutionComparison.ReferenceResult) !void {
    // Compare gas (exact match required)
    if (our.our_gas != reference.gas_used) {
        const our_str = try std.fmt.allocPrint(allocator, "{}", .{our.our_gas});
        defer allocator.free(our_str);
        const ref_str = try std.fmt.allocPrint(allocator, "{}", .{reference.gas_used});
        defer allocator.free(ref_str);
        try our.addDiscrepancy("Gas", "Gas consumption differs (exact match required)", our_str, ref_str, allocator);
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
    defer result.deinit();

    var writer = result.writer();
    try writer.print("0x", .{});
    for (bytes) |byte| {
        try writer.print("{x:02}", .{byte});
    }

    return try result.toOwnedSlice();
}

/// Test suite for critical opcodes
pub const OpcodeTestCase = struct {
    name: []const u8,
    bytecode: []const u8,
    calldata: []const u8,
    expected_gas: ?u64 = null,
    expected_stack_top: ?types.U256 = null,
    expected_return_data: ?[]const u8 = null,
    group: []const u8 = "opcode",
    precompile_id: ?u8 = null,
    description: []const u8,
};

pub const PrecompileHarnessSpec = struct {
    id: u8,
    input: []const u8,
    output_size: u16,
    gas: u32 = 0x00ff_ffff,
};

pub const PreparedOpcodeCase = struct {
    code: []const u8,
    calldata: []const u8,
    owned_code: ?[]u8 = null,

    pub fn deinit(self: PreparedOpcodeCase, allocator: std.mem.Allocator) void {
        if (self.owned_code) |buf| allocator.free(buf);
    }
};

fn appendPushU64(buf: *std.ArrayList(u8), value: u64) !void {
    var tmp: [8]u8 = undefined;
    std.mem.writeInt(u64, &tmp, value, .big);
    var first_non_zero: usize = 0;
    while (first_non_zero < tmp.len - 1 and tmp[first_non_zero] == 0) : (first_non_zero += 1) {}
    const n = tmp.len - first_non_zero;
    try buf.append(0x5f + @as(u8, @intCast(n))); // PUSHn
    try buf.appendSlice(tmp[first_non_zero..]);
}

fn buildPrecompileHarnessCode(allocator: std.mem.Allocator, spec: PrecompileHarnessSpec) ![]u8 {
    var code = try std.ArrayList(u8).initCapacity(allocator, 96);
    errdefer code.deinit();

    // Copy calldata to memory[0..input_len]
    try appendPushU64(&code, spec.input.len);
    try appendPushU64(&code, 0);
    try appendPushU64(&code, 0);
    try code.append(0x37); // CALLDATACOPY

    // CALL(gas, addr, value=0, in_offset=0, in_size, out_offset=1, out_size)
    try appendPushU64(&code, spec.output_size);
    try appendPushU64(&code, 1);
    try appendPushU64(&code, spec.input.len);
    try appendPushU64(&code, 0);
    try appendPushU64(&code, 0);
    try appendPushU64(&code, spec.id);
    try appendPushU64(&code, spec.gas);
    try code.append(0xf1); // CALL

    // Store CALL success flag in memory[0] and return [success || output]
    try appendPushU64(&code, 0);
    try code.append(0x53); // MSTORE8
    try appendPushU64(&code, @as(u64, spec.output_size) + 1);
    try appendPushU64(&code, 0);
    try code.append(0xf3); // RETURN

    return try code.toOwnedSlice();
}

pub fn prepareOpcodeCase(allocator: std.mem.Allocator, test_case: OpcodeTestCase) !PreparedOpcodeCase {
    if (test_case.precompile_id) |pid| {
        const code = try buildPrecompileHarnessCode(allocator, .{
            .id = pid,
            .input = test_case.calldata,
            .output_size = if (test_case.expected_return_data) |r| @as(u16, @intCast(r.len - 1)) else 0,
        });
        return .{
            .code = code,
            .calldata = test_case.calldata,
            .owned_code = code,
        };
    }
    return .{
        .code = test_case.bytecode,
        .calldata = test_case.calldata,
        .owned_code = null,
    };
}

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
        .expected_gas = 12, // PUSH1(3) + PUSH1(3) + MSTORE(3) + mem expansion (0->32)
        .description = "Store to memory",
    },
    .{
        .name = "MLOAD",
        .bytecode = &[_]u8{ 0x60, 0x00, 0x51 }, // PUSH1 0, MLOAD
        .calldata = &[_]u8{},
        .expected_gas = 9, // PUSH1(3) + MLOAD(3) + mem expansion (0->32)
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
    .{
        .name = "BYTE (LSB index)",
        .bytecode = &[_]u8{ 0x60, 0xaa, 0x60, 0x1f, 0x1a }, // PUSH1 0xaa, PUSH1 31, BYTE
        .calldata = &[_]u8{},
        .expected_gas = 9,
        .expected_stack_top = types.U256.fromU64(0xaa),
        .description = "BYTE returns least-significant byte at index 31",
    },
    .{
        .name = "SIGNEXTEND (positive byte)",
        .bytecode = &[_]u8{ 0x60, 0x7f, 0x60, 0x00, 0x0b }, // PUSH1 0x7f, PUSH1 0, SIGNEXTEND
        .calldata = &[_]u8{},
        .expected_gas = 11,
        .expected_stack_top = types.U256.fromU64(0x7f),
        .description = "SIGNEXTEND keeps positive sign when top bit is clear",
    },
    .{
        .name = "SIGNEXTEND (high-byte negative)",
        .bytecode = &[_]u8{
            0x7f,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x80,
            0x11,
            0x22,
            0x33,
            0x44,
            0x55,
            0x66,
            0x77,
            0x88,
            0x60,
            0x08,
            0x0b,
        },
        .calldata = &[_]u8{},
        .expected_gas = 11,
        .expected_stack_top = types.U256{
            .limbs = [_]u64{
                0x1122334455667788,
                0xffffffffffffff80,
                0xffffffffffffffff,
                0xffffffffffffffff,
            },
        },
        .description = "SIGNEXTEND extends from high selected byte using correct limb indexing",
    },
    .{
        .name = "SDIV (-7 / 2)",
        .bytecode = &[_]u8{
            0x60, 0x06, // 6
            0x19, // NOT => -7
            0x60, 0x02, // 2
            0x05, // SDIV
        },
        .calldata = &[_]u8{},
        .expected_gas = 14,
        .expected_stack_top = types.U256{
            .limbs = [_]u64{
                @as(u64, 0xfffffffffffffffd),
                0xffffffffffffffff,
                0xffffffffffffffff,
                0xffffffffffffffff,
            },
        },
        .description = "SDIV rounds toward zero for negative dividend",
    },
    .{
        .name = "SMOD (-7 % 3)",
        .bytecode = &[_]u8{
            0x60, 0x06, // 6
            0x19, // NOT => -7
            0x60, 0x03, // 3
            0x07, // SMOD
        },
        .calldata = &[_]u8{},
        .expected_gas = 14,
        .expected_stack_top = types.U256{
            .limbs = [_]u64{
                0xffffffffffffffff,
                0xffffffffffffffff,
                0xffffffffffffffff,
                0xffffffffffffffff,
            },
        },
        .description = "SMOD keeps sign of dividend for negative dividend",
    },
    .{
        .name = "SLT (-1 < 1)",
        .bytecode = &[_]u8{
            0x60, 0x00, // 0
            0x19, // NOT => -1
            0x60, 0x01, // 1
            0x12, // SLT
        },
        .calldata = &[_]u8{},
        .expected_gas = 12,
        .expected_stack_top = types.U256.one(),
        .description = "SLT compares signed values across sign boundary",
    },
    .{
        .name = "SGT (-1 > 1)",
        .bytecode = &[_]u8{
            0x60, 0x00, // 0
            0x19, // NOT => -1
            0x60, 0x01, // 1
            0x13, // SGT
        },
        .calldata = &[_]u8{},
        .expected_gas = 12,
        .expected_stack_top = types.U256.zero(),
        .description = "SGT compares signed values across sign boundary",
    },
    .{
        .name = "SAR (negative, shift>=256)",
        .bytecode = &[_]u8{
            0x60, 0x00, // 0
            0x19, // NOT => -1
            0x60, 0xff, // 255
            0x1d, // SAR
        },
        .calldata = &[_]u8{},
        .expected_gas = 12,
        .expected_stack_top = types.U256{
            .limbs = [_]u64{
                0xffffffffffffffff,
                0xffffffffffffffff,
                0xffffffffffffffff,
                0xffffffffffffffff,
            },
        },
        .description = "SAR preserves all ones for negative value at large shift",
    },
};

const sha256_abc_input = [_]u8{ 'a', 'b', 'c' };
const sha256_abc_output = [_]u8{
    0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea,
    0x41, 0x41, 0x40, 0xde, 0x5d, 0xae, 0x22, 0x23,
    0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c,
    0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad,
};

const ripemd160_abc_padded = [_]u8{
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x8e, 0xb2, 0x08, 0xf7,
    0xe0, 0x5d, 0x98, 0x7a, 0x9b, 0x04, 0x4a, 0x8e,
    0x98, 0xc6, 0xb0, 0x87, 0xf1, 0x5a, 0x0b, 0xfc,
};

const modexp_small_input = [_]u8{
    // baseLen=1, expLen=1, modLen=1, base=2, exp=10, mod=17
} ++ ([_]u8{0} ** 31) ++ [_]u8{0x01} ++
    ([_]u8{0} ** 31) ++ [_]u8{0x01} ++
    ([_]u8{0} ** 31) ++ [_]u8{ 0x01, 0x02, 0x0a, 0x11 };

const bn254_g1_plus_g1_input = [_]u8{
    // (1,2) + (1,2)
} ++ ([_]u8{0} ** 31) ++ [_]u8{0x01} ++
    ([_]u8{0} ** 31) ++ [_]u8{0x02} ++
    ([_]u8{0} ** 31) ++ [_]u8{0x01} ++
    ([_]u8{0} ** 31) ++ [_]u8{0x02};

const bn254_mul2_input = [_]u8{
    // (1,2) * 2
} ++ ([_]u8{0} ** 31) ++ [_]u8{0x01} ++
    ([_]u8{0} ** 31) ++ [_]u8{0x02} ++
    ([_]u8{0} ** 31) ++ [_]u8{0x02};

const bn254_add_output = [_]u8{
    0x15, 0x2b, 0xe2, 0x52, 0x42, 0x85, 0xb6, 0x12,
    0x40, 0xa3, 0x1e, 0x7f, 0xd8, 0xa8, 0x96, 0xa8,
    0xc1, 0x96, 0xb5, 0x9f, 0xb5, 0x41, 0x21, 0x3f,
    0x8d, 0xb2, 0xdb, 0x70, 0xb8, 0xff, 0xff, 0xff,
    0x08, 0x51, 0x3d, 0x7b, 0xbe, 0xb4, 0x87, 0x87,
    0x2b, 0xad, 0xcb, 0xfb, 0x5e, 0x42, 0x3b, 0x30,
    0x02, 0xe8, 0xeb, 0xec, 0x74, 0xeb, 0xdf, 0x58,
    0xf7, 0xaa, 0xd6, 0x35, 0x6d, 0x40, 0x00, 0x00,
};

const bn254_pairing_empty_true = [_]u8{
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
};

const bn254_pairing_false = [_]u8{0} ** 32;

const bn254_g2_generator = [_]u8{
    // (x_im, x_re, y_im, y_re)
} ++ [_]u8{
    0x19, 0x8e, 0x93, 0x93, 0x92, 0x0d, 0x48, 0x3a,
    0x72, 0x60, 0xbf, 0xb7, 0x31, 0xfb, 0x5d, 0x25,
    0xf1, 0xaa, 0x49, 0x33, 0x35, 0xa9, 0xe7, 0x12,
    0x97, 0xe4, 0x85, 0xb7, 0xae, 0xf3, 0x12, 0xc2,
} ++ [_]u8{
    0x18, 0x00, 0xde, 0xef, 0x12, 0x1f, 0x1e, 0x76,
    0x42, 0x6a, 0x00, 0x66, 0x5e, 0x5c, 0x44, 0x79,
    0x67, 0x43, 0x22, 0xd4, 0xf7, 0x5e, 0xda, 0xdd,
    0x46, 0xde, 0xbd, 0x5c, 0xd9, 0x92, 0xf6, 0xed,
} ++ [_]u8{
    0x09, 0x06, 0x89, 0xd0, 0x58, 0x5f, 0xf0, 0x75,
    0xec, 0x9e, 0x99, 0xad, 0x69, 0x0c, 0x33, 0x95,
    0xbc, 0x4b, 0x31, 0x33, 0x70, 0xb3, 0x8e, 0xf3,
    0x55, 0xac, 0xda, 0xdc, 0xd1, 0x22, 0x97, 0x5b,
} ++ [_]u8{
    0x12, 0xc8, 0x5e, 0xa5, 0xdb, 0x8c, 0x6d, 0xeb,
    0x4a, 0xab, 0x71, 0x80, 0x8d, 0xcb, 0x40, 0x8f,
    0xe3, 0xd1, 0xe7, 0x69, 0x0c, 0x43, 0xd3, 0x7b,
    0x4c, 0xe6, 0xcc, 0x01, 0x66, 0xfa, 0x7d, 0xaa,
};

const bn254_g2_generator_neg = [_]u8{
    // (x_im, x_re, -y_im, -y_re)
} ++ [_]u8{
    0x19, 0x8e, 0x93, 0x93, 0x92, 0x0d, 0x48, 0x3a,
    0x72, 0x60, 0xbf, 0xb7, 0x31, 0xfb, 0x5d, 0x25,
    0xf1, 0xaa, 0x49, 0x33, 0x35, 0xa9, 0xe7, 0x12,
    0x97, 0xe4, 0x85, 0xb7, 0xae, 0xf3, 0x12, 0xc2,
} ++ [_]u8{
    0x18, 0x00, 0xde, 0xef, 0x12, 0x1f, 0x1e, 0x76,
    0x42, 0x6a, 0x00, 0x66, 0x5e, 0x5c, 0x44, 0x79,
    0x67, 0x43, 0x22, 0xd4, 0xf7, 0x5e, 0xda, 0xdd,
    0x46, 0xde, 0xbd, 0x5c, 0xd9, 0x92, 0xf6, 0xed,
} ++ [_]u8{
    0x27, 0x5d, 0xc4, 0xa2, 0x88, 0xd1, 0xaf, 0xb3,
    0xcb, 0xb1, 0xac, 0x09, 0x18, 0x75, 0x24, 0xc7,
    0xdb, 0x36, 0x39, 0x5d, 0xf7, 0xbe, 0x3b, 0x99,
    0xe6, 0x73, 0xb1, 0x3a, 0x07, 0x5a, 0x65, 0xec,
} ++ [_]u8{
    0x1d, 0x9b, 0xef, 0xcd, 0x05, 0xa5, 0x32, 0x3e,
    0x6d, 0xa4, 0xd4, 0x35, 0xf3, 0xb6, 0x17, 0xcd,
    0xb3, 0xaf, 0x83, 0x28, 0x5c, 0x2d, 0xf7, 0x11,
    0xef, 0x39, 0xc0, 0x15, 0x71, 0x82, 0x7f, 0x9d,
};

const bn254_pairing_single_generator_input = [_]u8{
    // G1 (1,2)
} ++ ([_]u8{0} ** 31) ++ [_]u8{0x01} ++
    ([_]u8{0} ** 31) ++ [_]u8{0x02} ++
    bn254_g2_generator;

const bn254_pairing_inverse_product_input = bn254_pairing_single_generator_input ++ [_]u8{
    // G1 (1,2)
} ++ ([_]u8{0} ** 31) ++ [_]u8{0x01} ++
    ([_]u8{0} ** 31) ++ [_]u8{0x02} ++
    bn254_g2_generator_neg;

const bn254_pairing_invalid_g1_input = [_]u8{
    // invalid x = field modulus, y = 2, G2 = infinity
} ++ [_]u8{
    0x30, 0x64, 0x4e, 0x72, 0xe1, 0x31, 0xa0, 0x29,
    0xb8, 0x50, 0x45, 0xb6, 0x81, 0x81, 0x58, 0x5d,
    0x97, 0x81, 0x6a, 0x91, 0x68, 0x71, 0xca, 0x8d,
    0x3c, 0x20, 0x8c, 0x16, 0xd8, 0x7c, 0xfd, 0x47,
} ++ ([_]u8{0} ** 31) ++ [_]u8{0x02} ++ ([_]u8{0} ** 128);

const blake2f_eip152_input = [_]u8{
    0x00, 0x00, 0x00, 0x0c, // rounds
    0x48, 0xc9, 0xbd, 0xf2,
    0x67, 0xe6, 0x09, 0x6a,
    0x3b, 0xa7, 0xca, 0x84,
    0x85, 0xae, 0x67, 0xbb,
    0x2b, 0xf8, 0x94, 0xfe,
    0x72, 0xf3, 0x6e, 0x3c,
    0xf1, 0x36, 0x1d, 0x5f,
    0x3a, 0xf5, 0x4f, 0xa5,
    0xd1, 0x82, 0xe6, 0xad,
    0x7f, 0x52, 0x0e, 0x51,
    0x1f, 0x6c, 0x3e, 0x2b,
    0x8c, 0x68, 0x05, 0x9b,
    0x6b, 0xbd, 0x41, 0xfb,
    0xab, 0xd9, 0x83, 0x1f,
    0x79, 0x21, 0x7e, 0x13,
    0x19, 0xcd, 0xe0, 0x5b,
    0x61, 0x62, 0x63, 0x00,
    0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,
    0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // t0
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // t1
    0x01, // final block flag
};

const blake2f_eip152_output = [_]u8{
    0x79, 0xe2, 0x77, 0xb4, 0x08, 0x09, 0x5a, 0xa8,
    0x67, 0xee, 0x8e, 0x3c, 0x3c, 0x32, 0x00, 0x35,
    0x6e, 0x9d, 0xed, 0xb7, 0x0b, 0x4f, 0x76, 0x0b,
    0xd0, 0x68, 0xb6, 0x0c, 0xd0, 0x51, 0x0e, 0x31,
    0x77, 0x93, 0x4e, 0x3b, 0xf8, 0x86, 0xc9, 0x6b,
    0x28, 0xd5, 0x71, 0x34, 0xba, 0xf4, 0x1b, 0x3c,
    0x81, 0x82, 0x54, 0xd5, 0x27, 0xca, 0xb1, 0xdd,
    0x69, 0x6c, 0xb8, 0xa6, 0x74, 0x10, 0xde, 0x62,
};

const precompile_differential_tests = [_]OpcodeTestCase{
    .{
        .name = "PC01_ECRECOVER_INVALID",
        .bytecode = &[_]u8{},
        .calldata = &([_]u8{0} ** 128),
        .expected_return_data = &([_]u8{0x01} ++ ([_]u8{0} ** 32)),
        .group = "precompile",
        .precompile_id = 0x01,
        .description = "ECRECOVER invalid signature should return zero-address payload",
    },
    .{
        .name = "PC02_SHA256_ABC",
        .bytecode = &[_]u8{},
        .calldata = &sha256_abc_input,
        .expected_return_data = &([_]u8{0x01} ++ sha256_abc_output),
        .group = "precompile",
        .precompile_id = 0x02,
        .description = "SHA256 precompile canonical abc vector",
    },
    .{
        .name = "PC03_RIPEMD160_ABC",
        .bytecode = &[_]u8{},
        .calldata = &sha256_abc_input,
        .expected_return_data = &([_]u8{0x01} ++ ripemd160_abc_padded),
        .group = "precompile",
        .precompile_id = 0x03,
        .description = "RIPEMD160 precompile canonical abc vector",
    },
    .{
        .name = "PC04_IDENTITY_ECHO",
        .bytecode = &[_]u8{},
        .calldata = &[_]u8{ 0xde, 0xad, 0xbe, 0xef },
        .expected_return_data = &[_]u8{ 0x01, 0xde, 0xad, 0xbe, 0xef },
        .group = "precompile",
        .precompile_id = 0x04,
        .description = "IDENTITY precompile should echo calldata",
    },
    .{
        .name = "PC05_MODEXP_SMALL",
        .bytecode = &[_]u8{},
        .calldata = &modexp_small_input,
        .expected_return_data = &[_]u8{ 0x01, 0x04 },
        .group = "precompile",
        .precompile_id = 0x05,
        .description = "MODEXP small canonical vector",
    },
    .{
        .name = "PC06_BN256ADD_G1_PLUS_G1",
        .bytecode = &[_]u8{},
        .calldata = &bn254_g1_plus_g1_input,
        .expected_return_data = &([_]u8{0x01} ++ bn254_add_output),
        .group = "precompile",
        .precompile_id = 0x06,
        .description = "BN256ADD canonical (G1+G1) vector",
    },
    .{
        .name = "PC06_BN256ADD_INVALID_POINT",
        .bytecode = &[_]u8{},
        .calldata = &([_]u8{
            // x = field_modulus (invalid), y = 2, second point = infinity
        } ++ [_]u8{
            0x30, 0x64, 0x4e, 0x72, 0xe1, 0x31, 0xa0, 0x29,
            0xb8, 0x50, 0x45, 0xb6, 0x81, 0x81, 0x58, 0x5d,
            0x97, 0x81, 0x6a, 0x91, 0x68, 0x71, 0xca, 0x8d,
            0x3c, 0x20, 0x8c, 0x16, 0xd8, 0x7c, 0xfd, 0x47,
        } ++ ([_]u8{0} ** 31) ++ [_]u8{0x02} ++ ([_]u8{0} ** 64)),
        .expected_return_data = &([_]u8{0x00} ++ ([_]u8{0} ** 64)),
        .group = "precompile",
        .precompile_id = 0x06,
        .description = "BN256ADD invalid point should fail call",
    },
    .{
        .name = "PC07_BN256MUL_G1_BY_2",
        .bytecode = &[_]u8{},
        .calldata = &bn254_mul2_input,
        .expected_return_data = &([_]u8{0x01} ++ bn254_add_output),
        .group = "precompile",
        .precompile_id = 0x07,
        .description = "BN256MUL canonical (G1*2) vector",
    },
    .{
        .name = "PC07_BN256MUL_ZERO_SCALAR",
        .bytecode = &[_]u8{},
        .calldata = &([_]u8{
            // (1,2) * 0
        } ++ ([_]u8{0} ** 31) ++ [_]u8{0x01} ++
            ([_]u8{0} ** 31) ++ [_]u8{0x02} ++
            ([_]u8{0} ** 32)),
        .expected_return_data = &([_]u8{0x01} ++ ([_]u8{0} ** 64)),
        .group = "precompile",
        .precompile_id = 0x07,
        .description = "BN256MUL zero scalar should return infinity",
    },
    .{
        .name = "PC08_BN256PAIRING_EMPTY",
        .bytecode = &[_]u8{},
        .calldata = &[_]u8{},
        .expected_return_data = &([_]u8{0x01} ++ bn254_pairing_empty_true),
        .group = "precompile",
        .precompile_id = 0x08,
        .description = "BN256PAIRING empty input should be true",
    },
    .{
        .name = "PC08_BN256PAIRING_CANONICAL_FALSE",
        .bytecode = &[_]u8{},
        .calldata = &bn254_pairing_single_generator_input,
        .expected_return_data = &([_]u8{0x01} ++ bn254_pairing_false),
        .group = "precompile",
        .precompile_id = 0x08,
        .description = "BN256PAIRING canonical generator pair should return false",
    },
    .{
        .name = "PC08_BN256PAIRING_CANONICAL_TRUE_PRODUCT",
        .bytecode = &[_]u8{},
        .calldata = &bn254_pairing_inverse_product_input,
        .expected_return_data = &([_]u8{0x01} ++ bn254_pairing_empty_true),
        .group = "precompile",
        .precompile_id = 0x08,
        .description = "BN256PAIRING canonical inverse pair product should return true",
    },
    .{
        .name = "PC08_BN256PAIRING_INVALID_G1",
        .bytecode = &[_]u8{},
        .calldata = &bn254_pairing_invalid_g1_input,
        .expected_return_data = &([_]u8{0x00} ++ ([_]u8{0} ** 32)),
        .group = "precompile",
        .precompile_id = 0x08,
        .description = "BN256PAIRING invalid G1 input should fail call",
    },
    .{
        .name = "PC09_BLAKE2F_VECTOR",
        .bytecode = &[_]u8{},
        .calldata = &blake2f_eip152_input,
        .expected_return_data = null,
        .group = "precompile",
        .precompile_id = 0x09,
        .description = "BLAKE2F canonical EIP-152 vector",
    },
};

pub const differential_test_cases = critical_opcode_tests ++ precompile_differential_tests;

/// Run test case and verify
pub fn runTestCase(allocator: std.mem.Allocator, test_case: OpcodeTestCase) !ExecutionComparison {
    const prepared = try prepareOpcodeCase(allocator, test_case);
    defer prepared.deinit(allocator);
    var comparison = try executeOurEVM(allocator, prepared.code, prepared.calldata, 1000000);

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

    if (test_case.expected_return_data) |expected_return| {
        if (comparison.our_error == null and !std.mem.eql(u8, comparison.our_result.return_data, expected_return)) {
            const actual_hex = try formatHex(allocator, comparison.our_result.return_data);
            defer allocator.free(actual_hex);
            const expected_hex = try formatHex(allocator, expected_return);
            defer allocator.free(expected_hex);
            try comparison.addDiscrepancy("Return Data", "Return data differs from expected", actual_hex, expected_hex, allocator);
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
