//! zkVM I/O abstraction layer.
//!
//! Provides host communication for zkVM guest programs (SP1, RISC Zero, Jolt).
//! On freestanding (rv32im inside a prover): reads/writes go through global
//! buffers that the host populates before execution and reads after execution.
//! On native (testing): same buffers, populated directly by test harness code.
//!
//! Future: swap in SP1 env::read()/env::commit() or RISC Zero syscalls by
//! changing the read/commit implementations behind the comptime branch.

const std = @import("std");
const builtin = @import("builtin");

const is_freestanding = builtin.os.tag == .freestanding;

// ---------------------------------------------------------------------------
// Global I/O buffers
// ---------------------------------------------------------------------------
// 1 MB each — large enough for block-level witness data.
// On zkVM these live in guest memory; the host pre-fills input_buffer before
// execution begins and reads output_buffer after the guest halts.

pub var input_buffer: [1024 * 1024]u8 = undefined;
pub var input_len: usize = 0;

pub var output_buffer: [1024 * 1024]u8 = undefined;
pub var output_len: usize = 0;

// ---------------------------------------------------------------------------
// Reader: sequential cursor over the input buffer
// ---------------------------------------------------------------------------

pub const Reader = struct {
    pos: usize,

    pub fn init() Reader {
        return .{ .pos = 0 };
    }

    pub fn readBytes(self: *Reader, n: usize) ?[]const u8 {
        if (self.pos + n > input_len) return null;
        const slice = input_buffer[self.pos..][0..n];
        self.pos += n;
        return slice;
    }

    pub fn readU32(self: *Reader) ?u32 {
        const bytes = self.readBytes(4) orelse return null;
        return std.mem.readInt(u32, bytes[0..4], .little);
    }

    pub fn readU64(self: *Reader) ?u64 {
        const bytes = self.readBytes(8) orelse return null;
        return std.mem.readInt(u64, bytes[0..8], .little);
    }

    pub fn readAddress(self: *Reader) ?[20]u8 {
        const bytes = self.readBytes(20) orelse return null;
        var addr: [20]u8 = undefined;
        @memcpy(&addr, bytes);
        return addr;
    }
};

// ---------------------------------------------------------------------------
// Writer: sequential cursor over the output buffer
// ---------------------------------------------------------------------------

pub const Writer = struct {
    pos: usize,

    pub fn init() Writer {
        return .{ .pos = 0 };
    }

    pub fn writeByte(self: *Writer, byte: u8) bool {
        if (self.pos + 1 > output_buffer.len) return false;
        output_buffer[self.pos] = byte;
        self.pos += 1;
        return true;
    }

    pub fn writeU32(self: *Writer, value: u32) bool {
        if (self.pos + 4 > output_buffer.len) return false;
        std.mem.writeInt(u32, output_buffer[self.pos..][0..4], value, .little);
        self.pos += 4;
        return true;
    }

    pub fn writeU64(self: *Writer, value: u64) bool {
        if (self.pos + 8 > output_buffer.len) return false;
        std.mem.writeInt(u64, output_buffer[self.pos..][0..8], value, .little);
        self.pos += 8;
        return true;
    }

    pub fn writeBytes(self: *Writer, data: []const u8) bool {
        if (self.pos + data.len > output_buffer.len) return false;
        @memcpy(output_buffer[self.pos..][0..data.len], data);
        self.pos += data.len;
        return true;
    }

    /// Flush: record total bytes written so the host knows how much to read.
    pub fn finish(self: *Writer) void {
        output_len = self.pos;
    }
};

// ---------------------------------------------------------------------------
// High-level host I/O (matches SP1/RISC Zero env API shape)
// ---------------------------------------------------------------------------

pub const IO = struct {
    /// Read the entire input provided by the host.
    /// Returns a slice into the global input_buffer.
    pub fn readInput() []const u8 {
        return input_buffer[0..input_len];
    }

    /// Commit output data to the host (becomes part of the proof public output).
    /// Appends to the output_buffer. Returns false if the buffer is full.
    pub fn commit(data: []const u8) bool {
        if (output_len + data.len > output_buffer.len) return false;
        @memcpy(output_buffer[output_len..][0..data.len], data);
        output_len += data.len;
        return true;
    }

    /// Reset output (useful between test runs).
    pub fn resetOutput() void {
        output_len = 0;
    }

    /// Reset input (useful between test runs).
    pub fn resetInput() void {
        input_len = 0;
    }

    /// Reset all I/O state.
    pub fn reset() void {
        input_len = 0;
        output_len = 0;
    }
};

// ===========================================================================
// Tests
// ===========================================================================

test "Reader: sequential read of mixed types" {
    IO.reset();

    // Write a u32 (42), a u64 (1000), and 3 raw bytes into input_buffer.
    std.mem.writeInt(u32, input_buffer[0..4], 42, .little);
    std.mem.writeInt(u64, input_buffer[4..12], 1000, .little);
    input_buffer[12] = 0xAA;
    input_buffer[13] = 0xBB;
    input_buffer[14] = 0xCC;
    input_len = 15;

    var r = Reader.init();
    try std.testing.expectEqual(@as(u32, 42), r.readU32().?);
    try std.testing.expectEqual(@as(u64, 1000), r.readU64().?);
    const bytes = r.readBytes(3).?;
    try std.testing.expectEqual(@as(u8, 0xAA), bytes[0]);
    try std.testing.expectEqual(@as(u8, 0xBB), bytes[1]);
    try std.testing.expectEqual(@as(u8, 0xCC), bytes[2]);

    // Past end returns null.
    try std.testing.expect(r.readU32() == null);
}

test "Writer: sequential write and finish" {
    IO.reset();

    var w = Writer.init();
    try std.testing.expect(w.writeByte(1));
    try std.testing.expect(w.writeU64(999));
    try std.testing.expect(w.writeU32(7));
    const payload = [_]u8{ 0xDE, 0xAD };
    try std.testing.expect(w.writeBytes(&payload));
    w.finish();

    try std.testing.expectEqual(@as(usize, 1 + 8 + 4 + 2), output_len);
    try std.testing.expectEqual(@as(u8, 1), output_buffer[0]);
    try std.testing.expectEqual(@as(u64, 999), std.mem.readInt(u64, output_buffer[1..9], .little));
    try std.testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, output_buffer[9..13], .little));
    try std.testing.expectEqual(@as(u8, 0xDE), output_buffer[13]);
    try std.testing.expectEqual(@as(u8, 0xAD), output_buffer[14]);
}

test "IO: commit appends to output" {
    IO.reset();

    const a = [_]u8{ 0x01, 0x02 };
    const b = [_]u8{ 0x03, 0x04, 0x05 };
    try std.testing.expect(IO.commit(&a));
    try std.testing.expect(IO.commit(&b));

    try std.testing.expectEqual(@as(usize, 5), output_len);
    try std.testing.expectEqual(@as(u8, 0x01), output_buffer[0]);
    try std.testing.expectEqual(@as(u8, 0x05), output_buffer[4]);
}

test "Reader: readAddress returns 20 bytes" {
    IO.reset();

    var expected: [20]u8 = undefined;
    for (&expected, 0..) |*byte, i| {
        byte.* = @intCast(i + 1);
        input_buffer[i] = byte.*;
    }
    input_len = 20;

    var r = Reader.init();
    const addr = r.readAddress().?;
    try std.testing.expectEqualSlices(u8, &expected, &addr);
}
