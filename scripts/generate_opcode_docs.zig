//! Generate opcode documentation from EVM implementation.
//! zig build opcode-docs [-- docs/opcodes.md]

const std = @import("std");
const evm = @import("evm");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var out_path: ?[]const u8 = null;
    var args = std.process.args();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--")) {
            if (args.next()) |p| out_path = p;
            break;
        }
    }

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    try buf.writer().print(
        \\# Zeth Opcode Reference
        \\Auto-generated from implementation. Run `zig build opcode-docs` to refresh.
        \\
        \\## Implemented Opcodes
        \\
        \\| Code | Mnemonic |
        \\|------|----------|
        \\
    , .{});

    const Opcode = evm.Opcode;
    const enum_info = @typeInfo(Opcode).@"enum";
    inline for (enum_info.fields) |f| {
        const tag: Opcode = @field(Opcode, f.name);
        try buf.writer().print("| 0x{x:0>2} | {s} |\n", .{ @intFromEnum(tag), f.name });
    }
    try buf.writer().print(
        \\
        \\## Total
        \\
        \\{d} opcodes implemented.
        \\
    , .{enum_info.fields.len});

    const path = out_path orelse "docs/opcodes.md";
    try std.fs.cwd().writeFile(.{
        .sub_path = path,
        .data = buf.items,
    });
    std.debug.print("Wrote {s}\n", .{path});
}
