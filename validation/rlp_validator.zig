const std = @import("std");
const rlp = @import("rlp");

/// RLP Validation Against Official Ethereum Tests
/// This will show us where we're wrong.

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.debug.print("\n=== RLP Validation Against Ethereum Tests ===\n\n", .{});
    
    const test_file = try std.fs.cwd().openFile("ethereum-tests/RLPTests/rlptest.json", .{});
    defer test_file.close();
    
    const file_content = try test_file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(file_content);
    
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, file_content, .{});
    defer parsed.deinit();
    
    var total: usize = 0;
    var passed: usize = 0;
    var failed: usize = 0;
    
    const tests_obj = parsed.value.object;
    
    std.debug.print("Running {} RLP test cases...\n\n", .{tests_obj.count()});
    
    var iter = tests_obj.iterator();
    while (iter.next()) |entry| {
        const test_name = entry.key_ptr.*;
        const test_case = entry.value_ptr.*.object;
        
        total += 1;
        
        // Get expected output
        const out_hex = test_case.get("out").?.string;
        const expected = try hexToBytes(allocator, out_hex[2..]); // Skip "0x"
        defer allocator.free(expected);
        
        // Get input
        const in_value = test_case.get("in").?;
        
        // Encode based on type
        const result = try encodeValue(allocator, in_value);
        defer allocator.free(result);
        
        // Compare
        if (std.mem.eql(u8, expected, result)) {
            passed += 1;
            if (passed <= 5) {
                std.debug.print("✅ PASS: {s}\n", .{test_name});
            }
        } else {
            failed += 1;
            std.debug.print("❌ FAIL: {s}\n", .{test_name});
            std.debug.print("   Expected: 0x", .{});
            for (expected) |b| std.debug.print("{x:0>2}", .{b});
            std.debug.print("\n   Got:      0x", .{});
            for (result) |b| std.debug.print("{x:0>2}", .{b});
            std.debug.print("\n\n", .{});
            
            if (failed >= 10) {
                std.debug.print("(Stopping after 10 failures to avoid spam)\n\n", .{});
                break;
            }
        }
    }
    
    std.debug.print("\n=== RLP Validation Results ===\n", .{});
    std.debug.print("Total: {}\n", .{total});
    std.debug.print("Passed: {} ({d:.1}%)\n", .{passed, @as(f64, @floatFromInt(passed)) / @as(f64, @floatFromInt(total)) * 100});
    std.debug.print("Failed: {} ({d:.1}%)\n", .{failed, @as(f64, @floatFromInt(failed)) / @as(f64, @floatFromInt(total)) * 100});
    
    if (passed == total) {
        std.debug.print("\n🎉 ALL TESTS PASS! RLP implementation is correct!\n", .{});
    } else {
        std.debug.print("\n⚠️  We have bugs to fix. This is expected.\n", .{});
    }
}

fn encodeValue(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    switch (value) {
        .string => |s| {
            return try rlp.encodeBytes(s, allocator);
        },
        .integer => |i| {
            return try rlp.encodeU64(@intCast(i), allocator);
        },
        .array => |arr| {
            var items = try allocator.alloc([]const u8, arr.items.len);
            defer {
                for (items) |item| allocator.free(item);
                allocator.free(items);
            }
            
            for (arr.items, 0..) |item, idx| {
                items[idx] = try encodeValue(allocator, item);
            }
            
            return try rlp.encodeList(items, allocator);
        },
        else => {
            std.debug.print("Unknown type\n", .{});
            return error.UnsupportedType;
        },
    }
}

fn hexToBytes(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
    const result = try allocator.alloc(u8, hex.len / 2);
    var i: usize = 0;
    while (i < hex.len) : (i += 2) {
        result[i / 2] = try std.fmt.parseInt(u8, hex[i..i+2], 16);
    }
    return result;
}

