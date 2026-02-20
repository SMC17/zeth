//! Run test vectors (from VMTests --convert) and assert regression.
//! zig build vector-runner -- validation/test_vectors/generated.json

const std = @import("std");
const evm = @import("evm");
const types = @import("types");
const state = @import("state");

fn parseHex(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
    var s = hex;
    if (std.mem.startsWith(u8, s, "0x")) s = s[2..];
    if (s.len % 2 != 0) return error.InvalidHex;
    const out = try allocator.alloc(u8, s.len / 2);
    for (0..out.len) |i| {
        const hi = try nibble(s[i * 2]);
        const lo = try nibble(s[i * 2 + 1]);
        out[i] = (@as(u8, hi) << 4) | @as(u8, lo);
    }
    return out;
}
fn nibble(c: u8) !u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'f' => @intCast(c - 'a' + 10),
        'A'...'F' => @intCast(c - 'A' + 10),
        else => error.InvalidHex,
    };
}

const Vector = struct {
    name: []const u8,
    bytecode_hex: []const u8,
    calldata_hex: []const u8,
    gas_limit: u64,
    gas_used: u64,
    success: bool,
    return_data_hex: []const u8,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = std.process.args();
    _ = args.skip();
    const path = args.next() orelse {
        std.debug.print("Usage: vector_runner <vectors.json>\n", .{});
        std.debug.print("Generate vectors: zig build validate-vm -- --convert --out validation/test_vectors/generated.json\n", .{});
        std.process.exit(1);
    };

    const content = std.fs.cwd().readFileAlloc(allocator, path, 100 * 1024 * 1024) catch {
        std.debug.print("Failed to read {s}\n", .{path});
        std.process.exit(1);
    };
    defer allocator.free(content);

    var parsed = std.json.parseFromSlice(struct {
        vectors: []Vector,
        count: usize = 0,
    }, allocator, content, .{}) catch {
        std.debug.print("Invalid JSON\n", .{});
        std.process.exit(1);
    };
    defer parsed.deinit();

    const vectors = parsed.value.vectors;
    var passed: usize = 0;
    var failed: usize = 0;

    for (vectors) |vec| {
        const code = try parseHex(allocator, vec.bytecode_hex);
        defer allocator.free(code);

        const calldata = if (vec.calldata_hex.len > 2)
            try parseHex(allocator, vec.calldata_hex)
        else
            &[_]u8{};
        defer if (calldata.len > 0) allocator.free(calldata);

        var vm = try evm.EVM.init(allocator, vec.gas_limit);
        defer vm.deinit();

        const result = vm.execute(code, calldata) catch {
            if (!vec.success) {
                passed += 1;
            } else {
                failed += 1;
                std.debug.print("FAIL {s}: expected success\n", .{vec.name});
            }
            continue;
        };
        defer if (result.return_data.len > 0) allocator.free(result.return_data);
        defer allocator.free(result.logs);

        if (result.success != vec.success) {
            failed += 1;
            std.debug.print("FAIL {s}: success {} vs {}\n", .{ vec.name, result.success, vec.success });
            continue;
        }
        if (result.gas_used != vec.gas_used) {
            failed += 1;
            std.debug.print("FAIL {s}: gas {} vs {}\n", .{ vec.name, result.gas_used, vec.gas_used });
            continue;
        }

        const expected_ret = if (vec.return_data_hex.len > 2)
            try parseHex(allocator, vec.return_data_hex)
        else
            &[_]u8{};
        defer if (expected_ret.len > 0) allocator.free(expected_ret);

        if (!std.mem.eql(u8, result.return_data, expected_ret)) {
            failed += 1;
            std.debug.print("FAIL {s}: return data mismatch\n", .{vec.name});
            continue;
        }
        passed += 1;
    }

    std.debug.print("Vectors: {}/{} passed\n", .{ passed, passed + failed });
    if (failed > 0) std.process.exit(1);
}
