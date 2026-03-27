const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);
    if (argv.len != 3) {
        std.debug.print("usage: regression_gate <baseline.json> <current.json>\n", .{});
        return error.InvalidArguments;
    }

    try enforceBaseline(allocator, argv[1], argv[2]);
}

fn buildKey(allocator: std.mem.Allocator, opcode: []const u8, disc_type: []const u8, description: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}|{s}|{s}", .{ opcode, disc_type, description });
}

fn loadKeys(allocator: std.mem.Allocator, path: []const u8, keys: *std.StringHashMap(void), total: *usize) !void {
    const content = try std.fs.cwd().readFileAlloc(allocator, path, 4 * 1024 * 1024);
    defer allocator.free(content);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    total.* = @intCast(root.get("summary").?.object.get("total").?.integer);
    if (root.get("discrepancies")) |items| {
        for (items.array.items) |disc_val| {
            const disc = disc_val.object;
            const key = try buildKey(
                allocator,
                disc.get("opcode").?.string,
                disc.get("type").?.string,
                disc.get("description").?.string,
            );
            try keys.put(key, {});
        }
    }
}

fn enforceBaseline(allocator: std.mem.Allocator, baseline_path: []const u8, current_path: []const u8) !void {
    var baseline_keys = std.StringHashMap(void).init(allocator);
    defer {
        var it = baseline_keys.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        baseline_keys.deinit();
    }

    var current_keys = std.StringHashMap(void).init(allocator);
    defer {
        var it = current_keys.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        current_keys.deinit();
    }

    var baseline_total: usize = 0;
    var current_total: usize = 0;
    try loadKeys(allocator, baseline_path, &baseline_keys, &baseline_total);
    try loadKeys(allocator, current_path, &current_keys, &current_total);

    if (current_total > baseline_total) return error.DiscrepancyRegression;

    var current_it = current_keys.keyIterator();
    while (current_it.next()) |key| {
        if (!baseline_keys.contains(key.*)) return error.DiscrepancyRegression;
    }

    std.debug.print("regression_gate: no discrepancy regression\n", .{});
}
