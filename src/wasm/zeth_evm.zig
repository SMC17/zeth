//! zeth-wasm: Browser/edge EVM execution via WebAssembly
//!
//! Exports a minimal FFI for JS/embedders: execute bytecode in linear memory.
//! Target: wasm32-wasi or wasm32-freestanding.
//!
//! FFI: zeth_execute(input_ptr, input_len, output_ptr, output_cap) -> u32
//!   Input: [code_len:u32 LE][code][calldata_len:u32 LE][calldata]
//!   Output: [success:u8][gas_used:u64 LE][return_data_len:u32 LE][return_data...]
//!   Return: bytes written, or 0xFFFFFFFF on error

const std = @import("std");
const sim = @import("sim");

// Use a fixed buffer allocator for WASM to avoid page allocator issues.
// 256KB arena is enough for simple contract execution.
var wasm_arena_buf: [256 * 1024]u8 = undefined;
var wasm_arena = std.heap.FixedBufferAllocator.init(&wasm_arena_buf);

/// Execute EVM bytecode. Exported for JS/embedders.
/// Returns total bytes written to output, or 0xFFFFFFFF on error.
export fn zeth_execute(
    input_ptr: [*]const u8,
    input_len: u32,
    output_ptr: [*]u8,
    output_cap: u32,
) callconv(.C) u32 {
    if (input_len < 8) return 0xFFFFFFFF; // need at least code_len + calldata_len
    const input = input_ptr[0..input_len];

    const code_len = std.mem.readInt(u32, input[0..4], .little);
    if (4 + code_len + 4 > input_len) return 0xFFFFFFFF;
    const code = input[4..][0..code_len];
    const calldata_len = std.mem.readInt(u32, input[4 + code_len ..][0..4], .little);
    if (4 + code_len + 4 + calldata_len > input_len) return 0xFFFFFFFF;
    const calldata = input[4 + code_len + 4 ..][0..calldata_len];

    const output = output_ptr[0..output_cap];
    const min_output = 1 + 8 + 4; // success + gas_used + return_data_len
    if (output_cap < min_output) return 0xFFFFFFFF;

    wasm_arena.reset();
    const allocator = wasm_arena.allocator();

    var result = sim.execute(allocator, code, calldata, sim.ExecutionRequest.default()) catch return 0xFFFFFFFF;
    defer result.deinit();

    output[0] = if (result.success) 1 else 0;
    std.mem.writeInt(u64, output[1..9], result.gas_used, .little);
    const rd_len: u32 = @intCast(result.return_data.len);
    std.mem.writeInt(u32, output[9..13], rd_len, .little);
    const total = min_output + rd_len;
    if (output_cap < total) return 0xFFFFFFFF;
    @memcpy(output[13..][0..result.return_data.len], result.return_data);
    return total;
}
