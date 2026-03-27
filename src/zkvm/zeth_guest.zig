//! zkVM guest program entry point for Zeth.
//!
//! This module implements a complete zkVM guest that:
//!   1. Reads transaction input from the host via the I/O layer
//!   2. Executes the transaction using the Zeth EVM
//!   3. Commits the execution result back to the host
//!
//! The same code compiles for both native (testing) and rv32im-freestanding
//! (proving inside SP1, RISC Zero, or Jolt). The only difference is the I/O
//! backend — on freestanding, global buffers are memory-mapped by the host;
//! on native, tests populate them directly.
//!
//! Input protocol (binary, little-endian):
//!   [4 bytes]  code_len
//!   [code_len] bytecode
//!   [4 bytes]  calldata_len
//!   [calldata_len] calldata
//!   [8 bytes]  gas_limit
//!   [8 bytes]  value (u64, simplified — full U256 not needed for v1)
//!   [20 bytes] caller address
//!   [20 bytes] target address (all-zero = contract creation)
//!   [8 bytes]  block_number
//!   [8 bytes]  block_timestamp
//!
//! Output protocol (binary, little-endian):
//!   [1 byte]   success (0 or 1)
//!   [8 bytes]  gas_used
//!   [4 bytes]  return_data_len
//!   [return_data_len] return_data

const std = @import("std");
const builtin = @import("builtin");
const evm = @import("evm");
const types = @import("types");
const io = @import("io.zig");

const is_freestanding = builtin.os.tag == .freestanding;

// On freestanding targets, std.heap needs page size hints. When targeting
// riscv32-linux (as SP1/RISC Zero emulate), this is not needed, but we
// keep the conditional for future pure-freestanding support.
pub const std_options: std.Options = if (is_freestanding) .{
    .page_size_min = 4096,
    .page_size_max = 4096,
} else .{};

// ---------------------------------------------------------------------------
// Fixed-buffer allocator for guest execution
// ---------------------------------------------------------------------------
// zkVM guests cannot use a general-purpose allocator (no mmap, no brk).
// We carve out a static arena. 512KB is sufficient for single-tx execution.

var guest_arena_buf: [512 * 1024]u8 = undefined;
var guest_arena = std.heap.FixedBufferAllocator.init(&guest_arena_buf);

// ---------------------------------------------------------------------------
// Input parsing
// ---------------------------------------------------------------------------

const GuestInput = struct {
    code: []const u8,
    calldata: []const u8,
    gas_limit: u64,
    value: u64,
    caller: [20]u8,
    target: [20]u8,
    block_number: u64,
    block_timestamp: u64,
};

fn parseInput() ?GuestInput {
    var r = io.Reader.init();

    const code_len = r.readU32() orelse return null;
    const code = r.readBytes(code_len) orelse return null;

    const calldata_len = r.readU32() orelse return null;
    const calldata = r.readBytes(calldata_len) orelse return null;

    const gas_limit = r.readU64() orelse return null;
    const value = r.readU64() orelse return null;
    const caller = r.readAddress() orelse return null;
    const target = r.readAddress() orelse return null;
    const block_number = r.readU64() orelse return null;
    const block_timestamp = r.readU64() orelse return null;

    return GuestInput{
        .code = code,
        .calldata = calldata,
        .gas_limit = gas_limit,
        .value = value,
        .caller = caller,
        .target = target,
        .block_number = block_number,
        .block_timestamp = block_timestamp,
    };
}

// ---------------------------------------------------------------------------
// Output writing
// ---------------------------------------------------------------------------

fn writeOutput(success: bool, gas_used: u64, return_data: []const u8) void {
    var w = io.Writer.init();
    _ = w.writeByte(if (success) 1 else 0);
    _ = w.writeU64(gas_used);
    const rd_len: u32 = @intCast(@min(return_data.len, std.math.maxInt(u32)));
    _ = w.writeU32(rd_len);
    _ = w.writeBytes(return_data[0..rd_len]);
    w.finish();
}

fn writeError() void {
    writeOutput(false, 0, &[_]u8{});
}

// ---------------------------------------------------------------------------
// Guest entry point
// ---------------------------------------------------------------------------

/// zkVM entry point — called by the prover runtime.
/// On SP1/RISC Zero, _start -> main -> zeth_guest_execute.
pub fn main() void {
    zeth_guest_execute();
}

/// Execute a single transaction inside the zkVM.
/// Exported with C calling convention so the prover host can locate it.
export fn zeth_guest_execute() callconv(.C) void {
    // Reset arena between calls (idempotent for single-shot proving).
    guest_arena.reset();
    const allocator = guest_arena.allocator();

    const input = parseInput() orelse {
        writeError();
        return;
    };

    // Build execution context.
    var ctx = evm.ExecutionContext.default();
    ctx.caller = types.Address{ .bytes = input.caller };
    ctx.origin = types.Address{ .bytes = input.caller };
    ctx.address = types.Address{ .bytes = input.target };
    ctx.value = types.U256.fromU64(input.value);
    ctx.calldata = input.calldata;
    ctx.code = input.code;
    ctx.block_number = input.block_number;
    ctx.block_timestamp = input.block_timestamp;
    ctx.block_gaslimit = 30_000_000;
    ctx.chain_id = 1;

    // Create and run the EVM.
    var vm = evm.EVM.initWithContext(allocator, input.gas_limit, ctx) catch {
        writeError();
        return;
    };
    defer vm.deinit();

    const result = vm.execute(input.code, input.calldata) catch {
        // Hard OOG or allocator failure — report failure with full gas consumed.
        writeOutput(false, input.gas_limit, &[_]u8{});
        return;
    };

    writeOutput(result.success, result.gas_used, result.return_data);
}

// ---------------------------------------------------------------------------
// Helper: fill input buffer with a transaction (for tests and host tooling)
// ---------------------------------------------------------------------------

pub fn fillInput(
    code: []const u8,
    calldata: []const u8,
    gas_limit: u64,
    value: u64,
    caller: [20]u8,
    target: [20]u8,
    block_number: u64,
    block_timestamp: u64,
) void {
    io.IO.reset();

    var pos: usize = 0;
    const buf = &io.input_buffer;

    // code_len + code
    std.mem.writeInt(u32, buf[pos..][0..4], @intCast(code.len), .little);
    pos += 4;
    @memcpy(buf[pos..][0..code.len], code);
    pos += code.len;

    // calldata_len + calldata
    std.mem.writeInt(u32, buf[pos..][0..4], @intCast(calldata.len), .little);
    pos += 4;
    @memcpy(buf[pos..][0..calldata.len], calldata);
    pos += calldata.len;

    // gas_limit
    std.mem.writeInt(u64, buf[pos..][0..8], gas_limit, .little);
    pos += 8;

    // value
    std.mem.writeInt(u64, buf[pos..][0..8], value, .little);
    pos += 8;

    // caller
    @memcpy(buf[pos..][0..20], &caller);
    pos += 20;

    // target
    @memcpy(buf[pos..][0..20], &target);
    pos += 20;

    // block_number
    std.mem.writeInt(u64, buf[pos..][0..8], block_number, .little);
    pos += 8;

    // block_timestamp
    std.mem.writeInt(u64, buf[pos..][0..8], block_timestamp, .little);
    pos += 8;

    io.input_len = pos;
}

// ---------------------------------------------------------------------------
// Output parsing helper (for tests)
// ---------------------------------------------------------------------------

pub const GuestOutput = struct {
    success: bool,
    gas_used: u64,
    return_data: []const u8,
};

pub fn parseOutput() ?GuestOutput {
    if (io.output_len < 1 + 8 + 4) return null;
    const buf = &io.output_buffer;

    const success = buf[0] != 0;
    const gas_used = std.mem.readInt(u64, buf[1..9], .little);
    const rd_len = std.mem.readInt(u32, buf[9..13], .little);

    if (io.output_len < 13 + rd_len) return null;
    const return_data = buf[13..][0..rd_len];

    return GuestOutput{
        .success = success,
        .gas_used = gas_used,
        .return_data = return_data,
    };
}

// ===========================================================================
// Tests — run natively to validate the guest logic
// ===========================================================================

test "guest: PUSH1 42 STOP succeeds with gas > 0" {
    // Bytecode: PUSH1 0x2A, STOP
    const code = [_]u8{ 0x60, 0x2A, 0x00 };
    const caller = [_]u8{0} ** 19 ++ [_]u8{0xAA};
    const target = [_]u8{0} ** 19 ++ [_]u8{0xBB};

    fillInput(
        &code,
        &[_]u8{}, // no calldata
        100_000, // gas
        0, // value
        caller,
        target,
        15_000_000, // block number
        1_700_000_000, // timestamp
    );

    zeth_guest_execute();

    const out = parseOutput() orelse return error.OutputParseFailed;
    try std.testing.expect(out.success);
    try std.testing.expect(out.gas_used > 0);
    try std.testing.expect(out.gas_used < 100_000);
}

test "guest: empty code succeeds immediately" {
    const caller = [_]u8{0} ** 20;
    const target = [_]u8{0} ** 20;

    fillInput(
        &[_]u8{}, // empty code
        &[_]u8{},
        100_000,
        0,
        caller,
        target,
        1,
        1,
    );

    zeth_guest_execute();

    const out = parseOutput() orelse return error.OutputParseFailed;
    try std.testing.expect(out.success);
    try std.testing.expectEqual(@as(u64, 0), out.gas_used);
}

test "guest: ADD operation produces correct result" {
    // PUSH1 3, PUSH1 4, ADD, PUSH1 0, MSTORE, PUSH1 32, PUSH1 0, RETURN
    const code = [_]u8{
        0x60, 0x03, // PUSH1 3
        0x60, 0x04, // PUSH1 4
        0x01, // ADD
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN
    };
    const caller = [_]u8{0} ** 20;
    const target = [_]u8{0} ** 20;

    fillInput(&code, &[_]u8{}, 100_000, 0, caller, target, 1, 1);

    zeth_guest_execute();

    const out = parseOutput() orelse return error.OutputParseFailed;
    try std.testing.expect(out.success);
    try std.testing.expect(out.gas_used > 0);
    // Return data is 32 bytes (MSTORE word), last byte should be 7 (3+4).
    try std.testing.expectEqual(@as(usize, 32), out.return_data.len);
    try std.testing.expectEqual(@as(u8, 7), out.return_data[31]);
}

test "guest: insufficient gas reports failure" {
    // PUSH1 1, PUSH1 2, ADD — needs ~9 gas (3+3+3), give only 5
    const code = [_]u8{ 0x60, 0x01, 0x60, 0x02, 0x01 };
    const caller = [_]u8{0} ** 20;
    const target = [_]u8{0} ** 20;

    fillInput(&code, &[_]u8{}, 5, 0, caller, target, 1, 1);

    zeth_guest_execute();

    const out = parseOutput() orelse return error.OutputParseFailed;
    try std.testing.expect(!out.success);
}

test "guest: invalid input returns error output" {
    io.IO.reset();
    // Truncated input — only 2 bytes, cannot even read code_len.
    io.input_buffer[0] = 0xFF;
    io.input_buffer[1] = 0xFF;
    io.input_len = 2;

    zeth_guest_execute();

    const out = parseOutput() orelse return error.OutputParseFailed;
    try std.testing.expect(!out.success);
    try std.testing.expectEqual(@as(u64, 0), out.gas_used);
}

test "guest: round-trip fillInput/parseInput consistency" {
    const code = [_]u8{ 0x60, 0x01, 0x00 };
    const cd = [_]u8{ 0xAA, 0xBB };
    const caller = [_]u8{0} ** 19 ++ [_]u8{0x01};
    const target = [_]u8{0} ** 19 ++ [_]u8{0x02};

    fillInput(&code, &cd, 50_000, 100, caller, target, 42, 1234);

    const input = parseInput() orelse return error.ParseFailed;
    try std.testing.expectEqualSlices(u8, &code, input.code);
    try std.testing.expectEqualSlices(u8, &cd, input.calldata);
    try std.testing.expectEqual(@as(u64, 50_000), input.gas_limit);
    try std.testing.expectEqual(@as(u64, 100), input.value);
    try std.testing.expectEqualSlices(u8, &caller, &input.caller);
    try std.testing.expectEqualSlices(u8, &target, &input.target);
    try std.testing.expectEqual(@as(u64, 42), input.block_number);
    try std.testing.expectEqual(@as(u64, 1234), input.block_timestamp);
}
