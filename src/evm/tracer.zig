const std = @import("std");
const types = @import("types");

/// A single step captured during EVM execution, compatible with geth's
/// debug_traceTransaction structLog format.
pub const TraceStep = struct {
    pc: u64,
    op: u8,
    op_name: []const u8,
    gas: u64,
    gas_cost: u64,
    depth: u32,
    /// Snapshot of the stack at the point of capture (before opcode execution).
    /// Owned by the Tracer (cloned on capture).
    stack: []const types.U256,
    memory_size: u64,
    /// Set only for SSTORE operations.
    storage_key: ?types.U256 = null,
    /// Set only for SSTORE operations.
    storage_value: ?types.U256 = null,
};

/// Execution tracer that records per-step structured logs compatible with
/// geth's debug_traceTransaction JSON output.  When the tracer pointer on
/// the EVM is null (the default), the hot loop pays only a single pointer
/// comparison -- zero heap allocation, zero function-call overhead.
pub const Tracer = struct {
    enabled: bool = false,
    steps: std.ArrayList(TraceStep),
    allocator: std.mem.Allocator,
    gas_profile: GasProfile = .{},

    pub fn init(allocator: std.mem.Allocator) Tracer {
        return .{
            .enabled = false,
            .steps = std.ArrayList(TraceStep).init(allocator),
            .allocator = allocator,
            .gas_profile = .{},
        };
    }

    pub fn deinit(self: *Tracer) void {
        for (self.steps.items) |step| {
            self.allocator.free(step.stack);
        }
        self.steps.deinit();
    }

    /// Record a single execution step.  No-ops when `enabled` is false so
    /// callers don't need a separate branch.
    pub fn captureStep(self: *Tracer, step: TraceStep) !void {
        if (!self.enabled) return;
        // Clone the stack slice so the snapshot survives past the EVM mutating
        // its own stack array.
        const stack_copy = try self.allocator.dupe(types.U256, step.stack);
        var owned_step = step;
        owned_step.stack = stack_copy;
        try self.steps.append(owned_step);
    }

    /// Back-patch the gas cost of the most recently captured step.  Called
    /// after opcode dispatch so we know the actual cost.
    pub fn patchGasCost(self: *Tracer, gas_cost: u64) void {
        if (!self.enabled) return;
        if (self.steps.items.len == 0) return;
        self.steps.items[self.steps.items.len - 1].gas_cost = gas_cost;
        // Also feed the gas profiler.
        const op = self.steps.items[self.steps.items.len - 1].op;
        self.gas_profile.record(op, gas_cost);
    }

    // ---------------------------------------------------------------
    // JSON serialization (geth-compatible structLogs)
    // ---------------------------------------------------------------

    /// Serialize the trace to a JSON byte slice allocated with `allocator`.
    /// Caller owns the returned memory.
    pub fn toJson(self: *const Tracer, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8).init(allocator);
        errdefer buf.deinit();
        const writer = buf.writer();

        try writer.writeAll("{\"structLogs\":[");

        for (self.steps.items, 0..) |step, i| {
            if (i > 0) try writer.writeByte(',');
            try writer.writeAll("{\"pc\":");
            try std.fmt.formatInt(step.pc, 10, .lower, .{}, writer);
            try writer.writeAll(",\"op\":\"");
            try writer.writeAll(step.op_name);
            try writer.writeAll("\",\"gas\":");
            try std.fmt.formatInt(step.gas, 10, .lower, .{}, writer);
            try writer.writeAll(",\"gasCost\":");
            try std.fmt.formatInt(step.gas_cost, 10, .lower, .{}, writer);
            try writer.writeAll(",\"depth\":");
            try std.fmt.formatInt(step.depth, 10, .lower, .{}, writer);
            try writer.writeAll(",\"stack\":[");
            for (step.stack, 0..) |val, si| {
                if (si > 0) try writer.writeByte(',');
                try writer.writeAll("\"0x");
                try writeU256Hex(writer, val);
                try writer.writeByte('"');
            }
            try writer.writeAll("],\"memSize\":");
            try std.fmt.formatInt(step.memory_size, 10, .lower, .{}, writer);

            // Optional storage fields (SSTORE only).
            if (step.storage_key) |key| {
                try writer.writeAll(",\"storage\":{\"");
                try writer.writeAll("0x");
                try writeU256Hex(writer, key);
                try writer.writeAll("\":\"0x");
                if (step.storage_value) |val| {
                    try writeU256Hex(writer, val);
                } else {
                    try writer.writeByte('0');
                }
                try writer.writeAll("\"}");
            }

            try writer.writeByte('}');
        }

        try writer.writeAll("]}");
        return buf.toOwnedSlice();
    }
};

/// Write a U256 as a minimal hex string (no leading zeros, but at least "0").
fn writeU256Hex(writer: anytype, value: types.U256) !void {
    if (value.limbs[3] == 0 and value.limbs[2] == 0 and value.limbs[1] == 0) {
        // Fits in a single u64.
        try std.fmt.formatInt(value.limbs[0], 16, .lower, .{}, writer);
        return;
    }
    // Multi-limb: print from most-significant non-zero limb downward.
    var started = false;
    var i: usize = 4;
    while (i > 0) {
        i -= 1;
        if (started) {
            // Pad to 16 hex chars.
            try std.fmt.format(writer, "{x:0>16}", .{value.limbs[i]});
        } else if (value.limbs[i] != 0) {
            try std.fmt.formatInt(value.limbs[i], 16, .lower, .{}, writer);
            started = true;
        }
    }
    if (!started) {
        try writer.writeByte('0');
    }
}

/// Resolve an opcode byte to its mnemonic name without importing the evm
/// module (avoids a circular dependency).  Uses a comptime-generated table
/// from the Opcode enum defined in evm.zig, accessed indirectly via the
/// build-system module graph -- but since we deliberately avoid importing
/// evm here, we use a simple static lookup table instead.
pub fn opcodeNameFromByte(byte: u8) []const u8 {
    // The table is indexed by byte value.  Only populate the ~140 named
    // opcodes; everything else maps to "UNKNOWN".
    const table = comptime blk: {
        var t: [256][]const u8 = undefined;
        for (0..256) |i| {
            t[i] = "UNKNOWN";
        }
        t[0x00] = "STOP";
        t[0x01] = "ADD";
        t[0x02] = "MUL";
        t[0x03] = "SUB";
        t[0x04] = "DIV";
        t[0x05] = "SDIV";
        t[0x06] = "MOD";
        t[0x07] = "SMOD";
        t[0x08] = "ADDMOD";
        t[0x09] = "MULMOD";
        t[0x0a] = "EXP";
        t[0x0b] = "SIGNEXTEND";
        t[0x10] = "LT";
        t[0x11] = "GT";
        t[0x12] = "SLT";
        t[0x13] = "SGT";
        t[0x14] = "EQ";
        t[0x15] = "ISZERO";
        t[0x16] = "AND";
        t[0x17] = "OR";
        t[0x18] = "XOR";
        t[0x19] = "NOT";
        t[0x1a] = "BYTE";
        t[0x1b] = "SHL";
        t[0x1c] = "SHR";
        t[0x1d] = "SAR";
        t[0x20] = "SHA3";
        t[0x30] = "ADDRESS";
        t[0x31] = "BALANCE";
        t[0x32] = "ORIGIN";
        t[0x33] = "CALLER";
        t[0x34] = "CALLVALUE";
        t[0x35] = "CALLDATALOAD";
        t[0x36] = "CALLDATASIZE";
        t[0x37] = "CALLDATACOPY";
        t[0x38] = "CODESIZE";
        t[0x39] = "CODECOPY";
        t[0x3a] = "GASPRICE";
        t[0x3b] = "EXTCODESIZE";
        t[0x3c] = "EXTCODECOPY";
        t[0x3d] = "RETURNDATASIZE";
        t[0x3e] = "RETURNDATACOPY";
        t[0x3f] = "EXTCODEHASH";
        t[0x40] = "BLOCKHASH";
        t[0x41] = "COINBASE";
        t[0x42] = "TIMESTAMP";
        t[0x43] = "NUMBER";
        t[0x44] = "DIFFICULTY";
        t[0x45] = "GASLIMIT";
        t[0x46] = "CHAINID";
        t[0x47] = "SELFBALANCE";
        t[0x48] = "BASEFEE";
        t[0x49] = "BLOBHASH";
        t[0x4a] = "BLOBBASEFEE";
        t[0x50] = "POP";
        t[0x51] = "MLOAD";
        t[0x52] = "MSTORE";
        t[0x53] = "MSTORE8";
        t[0x54] = "SLOAD";
        t[0x55] = "SSTORE";
        t[0x56] = "JUMP";
        t[0x57] = "JUMPI";
        t[0x58] = "PC";
        t[0x59] = "MSIZE";
        t[0x5a] = "GAS";
        t[0x5b] = "JUMPDEST";
        t[0x5c] = "TLOAD";
        t[0x5d] = "TSTORE";
        t[0x5e] = "MCOPY";
        t[0x5f] = "PUSH0";
        // PUSH1..PUSH32 (0x60..0x7f)
        t[0x60] = "PUSH1";
        t[0x61] = "PUSH2";
        t[0x62] = "PUSH3";
        t[0x63] = "PUSH4";
        t[0x64] = "PUSH5";
        t[0x65] = "PUSH6";
        t[0x66] = "PUSH7";
        t[0x67] = "PUSH8";
        t[0x68] = "PUSH9";
        t[0x69] = "PUSH10";
        t[0x6a] = "PUSH11";
        t[0x6b] = "PUSH12";
        t[0x6c] = "PUSH13";
        t[0x6d] = "PUSH14";
        t[0x6e] = "PUSH15";
        t[0x6f] = "PUSH16";
        t[0x70] = "PUSH17";
        t[0x71] = "PUSH18";
        t[0x72] = "PUSH19";
        t[0x73] = "PUSH20";
        t[0x74] = "PUSH21";
        t[0x75] = "PUSH22";
        t[0x76] = "PUSH23";
        t[0x77] = "PUSH24";
        t[0x78] = "PUSH25";
        t[0x79] = "PUSH26";
        t[0x7a] = "PUSH27";
        t[0x7b] = "PUSH28";
        t[0x7c] = "PUSH29";
        t[0x7d] = "PUSH30";
        t[0x7e] = "PUSH31";
        t[0x7f] = "PUSH32";
        // DUP1..DUP16 (0x80..0x8f)
        t[0x80] = "DUP1";
        t[0x81] = "DUP2";
        t[0x82] = "DUP3";
        t[0x83] = "DUP4";
        t[0x84] = "DUP5";
        t[0x85] = "DUP6";
        t[0x86] = "DUP7";
        t[0x87] = "DUP8";
        t[0x88] = "DUP9";
        t[0x89] = "DUP10";
        t[0x8a] = "DUP11";
        t[0x8b] = "DUP12";
        t[0x8c] = "DUP13";
        t[0x8d] = "DUP14";
        t[0x8e] = "DUP15";
        t[0x8f] = "DUP16";
        // SWAP1..SWAP16 (0x90..0x9f)
        t[0x90] = "SWAP1";
        t[0x91] = "SWAP2";
        t[0x92] = "SWAP3";
        t[0x93] = "SWAP4";
        t[0x94] = "SWAP5";
        t[0x95] = "SWAP6";
        t[0x96] = "SWAP7";
        t[0x97] = "SWAP8";
        t[0x98] = "SWAP9";
        t[0x99] = "SWAP10";
        t[0x9a] = "SWAP11";
        t[0x9b] = "SWAP12";
        t[0x9c] = "SWAP13";
        t[0x9d] = "SWAP14";
        t[0x9e] = "SWAP15";
        t[0x9f] = "SWAP16";
        // LOG0..LOG4 (0xa0..0xa4)
        t[0xa0] = "LOG0";
        t[0xa1] = "LOG1";
        t[0xa2] = "LOG2";
        t[0xa3] = "LOG3";
        t[0xa4] = "LOG4";
        // System
        t[0xf0] = "CREATE";
        t[0xf1] = "CALL";
        t[0xf2] = "CALLCODE";
        t[0xf3] = "RETURN";
        t[0xf4] = "DELEGATECALL";
        t[0xf5] = "CREATE2";
        t[0xfa] = "STATICCALL";
        t[0xfd] = "REVERT";
        t[0xfe] = "INVALID";
        t[0xff] = "SELFDESTRUCT";
        break :blk t;
    };
    return table[byte];
}

/// Per-opcode gas attribution tracker.  Accumulates total gas and invocation
/// count for every opcode byte value (0-255).
pub const GasProfile = struct {
    opcode_gas: [256]u64 = [_]u64{0} ** 256,
    opcode_count: [256]u64 = [_]u64{0} ** 256,

    pub fn record(self: *GasProfile, op: u8, gas_cost: u64) void {
        self.opcode_gas[op] += gas_cost;
        self.opcode_count[op] += 1;
    }

    /// Print the top-N opcodes by total gas consumption to stderr.
    pub fn report(self: *const GasProfile) void {
        const stderr = std.io.getStdErr().writer();
        self.reportTo(stderr);
    }

    /// Write the top-20 opcodes by gas to an arbitrary writer.
    pub fn reportTo(self: *const GasProfile, writer: anytype) void {
        // Collect indices of opcodes that were actually used.
        var indices: [256]u8 = undefined;
        var count: usize = 0;
        for (0..256) |i| {
            if (self.opcode_count[i] > 0) {
                indices[count] = @intCast(i);
                count += 1;
            }
        }
        if (count == 0) return;

        // Simple insertion sort (max 256 elements).
        const used = indices[0..count];
        for (1..used.len) |i| {
            const key = used[i];
            var j: usize = i;
            while (j > 0 and self.opcode_gas[used[j - 1]] < self.opcode_gas[key]) {
                used[j] = used[j - 1];
                j -= 1;
            }
            used[j] = key;
        }

        const limit = @min(count, 20);
        writer.print("--- Gas Profile (top {d}) ---\n", .{limit}) catch return;
        writer.print("{s:<16} {s:>10} {s:>12}\n", .{ "Opcode", "Count", "Gas" }) catch return;
        for (used[0..limit]) |idx| {
            const name = opcodeNameFromByte(idx);
            writer.print("{s:<16} {d:>10} {d:>12}\n", .{
                name,
                self.opcode_count[idx],
                self.opcode_gas[idx],
            }) catch return;
        }
    }
};

// ===================================================================
// Tests
// ===================================================================
test "tracer disabled by default - no overhead" {
    const allocator = std.testing.allocator;
    var tracer = Tracer.init(allocator);
    defer tracer.deinit();

    // enabled is false, so captureStep should be a no-op.
    try tracer.captureStep(.{
        .pc = 0,
        .op = 0x60,
        .op_name = "PUSH1",
        .gas = 100000,
        .gas_cost = 3,
        .depth = 1,
        .stack = &[_]types.U256{},
        .memory_size = 0,
    });

    try std.testing.expectEqual(@as(usize, 0), tracer.steps.items.len);
}

test "tracer captures PUSH1 + ADD sequence with correct PCs" {
    const allocator = std.testing.allocator;
    var tracer = Tracer.init(allocator);
    tracer.enabled = true;
    defer tracer.deinit();

    // Simulate: PUSH1 0x01 at pc=0, PUSH1 0x02 at pc=2, ADD at pc=4
    try tracer.captureStep(.{
        .pc = 0,
        .op = 0x60, // PUSH1
        .op_name = "PUSH1",
        .gas = 100000,
        .gas_cost = 3,
        .depth = 1,
        .stack = &[_]types.U256{},
        .memory_size = 0,
    });
    try tracer.captureStep(.{
        .pc = 2,
        .op = 0x60, // PUSH1
        .op_name = "PUSH1",
        .gas = 99997,
        .gas_cost = 3,
        .depth = 1,
        .stack = &[_]types.U256{types.U256.fromU64(1)},
        .memory_size = 0,
    });
    try tracer.captureStep(.{
        .pc = 4,
        .op = 0x01, // ADD
        .op_name = "ADD",
        .gas = 99994,
        .gas_cost = 3,
        .depth = 1,
        .stack = &[_]types.U256{ types.U256.fromU64(1), types.U256.fromU64(2) },
        .memory_size = 0,
    });

    try std.testing.expectEqual(@as(usize, 3), tracer.steps.items.len);
    try std.testing.expectEqual(@as(u64, 0), tracer.steps.items[0].pc);
    try std.testing.expectEqual(@as(u64, 2), tracer.steps.items[1].pc);
    try std.testing.expectEqual(@as(u64, 4), tracer.steps.items[2].pc);
    try std.testing.expectEqual(@as(u8, 0x60), tracer.steps.items[0].op);
    try std.testing.expectEqual(@as(u8, 0x01), tracer.steps.items[2].op);
}

test "tracer stack snapshots are correct at each step" {
    const allocator = std.testing.allocator;
    var tracer = Tracer.init(allocator);
    tracer.enabled = true;
    defer tracer.deinit();

    // Step 0: empty stack
    try tracer.captureStep(.{
        .pc = 0,
        .op = 0x60,
        .op_name = "PUSH1",
        .gas = 10000,
        .gas_cost = 3,
        .depth = 1,
        .stack = &[_]types.U256{},
        .memory_size = 0,
    });
    // Step 1: stack has [0x42]
    try tracer.captureStep(.{
        .pc = 2,
        .op = 0x60,
        .op_name = "PUSH1",
        .gas = 9997,
        .gas_cost = 3,
        .depth = 1,
        .stack = &[_]types.U256{types.U256.fromU64(0x42)},
        .memory_size = 0,
    });
    // Step 2: stack has [0x42, 0x10]
    try tracer.captureStep(.{
        .pc = 4,
        .op = 0x01,
        .op_name = "ADD",
        .gas = 9994,
        .gas_cost = 3,
        .depth = 1,
        .stack = &[_]types.U256{ types.U256.fromU64(0x42), types.U256.fromU64(0x10) },
        .memory_size = 0,
    });

    // Verify snapshots are independent copies.
    try std.testing.expectEqual(@as(usize, 0), tracer.steps.items[0].stack.len);
    try std.testing.expectEqual(@as(usize, 1), tracer.steps.items[1].stack.len);
    try std.testing.expectEqual(@as(usize, 2), tracer.steps.items[2].stack.len);

    try std.testing.expectEqual(types.U256.fromU64(0x42), tracer.steps.items[1].stack[0]);
    try std.testing.expectEqual(types.U256.fromU64(0x42), tracer.steps.items[2].stack[0]);
    try std.testing.expectEqual(types.U256.fromU64(0x10), tracer.steps.items[2].stack[1]);
}

test "gas profiler counts opcodes correctly" {
    var profile = GasProfile{};

    profile.record(0x60, 3); // PUSH1
    profile.record(0x60, 3); // PUSH1
    profile.record(0x01, 3); // ADD
    profile.record(0x55, 20000); // SSTORE

    try std.testing.expectEqual(@as(u64, 2), profile.opcode_count[0x60]);
    try std.testing.expectEqual(@as(u64, 6), profile.opcode_gas[0x60]);
    try std.testing.expectEqual(@as(u64, 1), profile.opcode_count[0x01]);
    try std.testing.expectEqual(@as(u64, 3), profile.opcode_gas[0x01]);
    try std.testing.expectEqual(@as(u64, 1), profile.opcode_count[0x55]);
    try std.testing.expectEqual(@as(u64, 20000), profile.opcode_gas[0x55]);
    // Unused opcode should be zero.
    try std.testing.expectEqual(@as(u64, 0), profile.opcode_count[0xFE]);
}

test "JSON output is valid and has structLogs array" {
    const allocator = std.testing.allocator;
    var tracer = Tracer.init(allocator);
    tracer.enabled = true;
    defer tracer.deinit();

    try tracer.captureStep(.{
        .pc = 0,
        .op = 0x60,
        .op_name = "PUSH1",
        .gas = 100000,
        .gas_cost = 3,
        .depth = 1,
        .stack = &[_]types.U256{},
        .memory_size = 0,
    });
    try tracer.captureStep(.{
        .pc = 2,
        .op = 0x01,
        .op_name = "ADD",
        .gas = 99997,
        .gas_cost = 3,
        .depth = 1,
        .stack = &[_]types.U256{ types.U256.fromU64(1), types.U256.fromU64(2) },
        .memory_size = 32,
    });

    const json = try tracer.toJson(allocator);
    defer allocator.free(json);

    // Parse to validate well-formedness.
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const struct_logs = root.get("structLogs").?;
    try std.testing.expectEqual(@as(usize, 2), struct_logs.array.items.len);

    // Verify first entry fields.
    const first = struct_logs.array.items[0].object;
    try std.testing.expectEqual(@as(i64, 0), first.get("pc").?.integer);
    try std.testing.expect(std.mem.eql(u8, "PUSH1", first.get("op").?.string));
    try std.testing.expectEqual(@as(i64, 100000), first.get("gas").?.integer);
    try std.testing.expectEqual(@as(i64, 3), first.get("gasCost").?.integer);
    try std.testing.expectEqual(@as(i64, 1), first.get("depth").?.integer);

    // Second entry should have a stack with two elements.
    const second = struct_logs.array.items[1].object;
    try std.testing.expectEqual(@as(usize, 2), second.get("stack").?.array.items.len);
    try std.testing.expectEqual(@as(i64, 32), second.get("memSize").?.integer);
}

test "tracer with empty bytecode produces empty structLogs" {
    const allocator = std.testing.allocator;
    var tracer = Tracer.init(allocator);
    tracer.enabled = true;
    defer tracer.deinit();

    // No steps captured -- simulates empty bytecode.
    const json = try tracer.toJson(allocator);
    defer allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const struct_logs = root.get("structLogs").?;
    try std.testing.expectEqual(@as(usize, 0), struct_logs.array.items.len);
}

test "patchGasCost updates last step and feeds gas profiler" {
    const allocator = std.testing.allocator;
    var tracer = Tracer.init(allocator);
    tracer.enabled = true;
    defer tracer.deinit();

    try tracer.captureStep(.{
        .pc = 0,
        .op = 0x60,
        .op_name = "PUSH1",
        .gas = 100000,
        .gas_cost = 0, // unknown at capture time
        .depth = 1,
        .stack = &[_]types.U256{},
        .memory_size = 0,
    });
    tracer.patchGasCost(3);

    try std.testing.expectEqual(@as(u64, 3), tracer.steps.items[0].gas_cost);
    try std.testing.expectEqual(@as(u64, 3), tracer.gas_profile.opcode_gas[0x60]);
    try std.testing.expectEqual(@as(u64, 1), tracer.gas_profile.opcode_count[0x60]);
}

test "gas profiler report produces output" {
    var profile = GasProfile{};
    profile.record(0x01, 3); // ADD
    profile.record(0x01, 3); // ADD
    profile.record(0x55, 20000); // SSTORE

    var buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    profile.reportTo(fbs.writer());

    const output = fbs.getWritten();
    try std.testing.expect(output.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, output, "SSTORE") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "ADD") != null);
}
