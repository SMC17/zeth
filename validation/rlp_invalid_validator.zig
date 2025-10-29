const std = @import("std");
const rlp = @import("rlp");

/// Invalid RLP Validation
/// Ensure we REJECT malformed RLP correctly (don't crash, don't accept)

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.debug.print("\n=== Invalid RLP Rejection Testing ===\n\n", .{});
    
    const test_file = try std.fs.cwd().openFile("ethereum-tests/RLPTests/invalidRLPTest.json", .{});
    defer test_file.close();
    
    const file_content = try test_file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(file_content);
    
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, file_content, .{});
    defer parsed.deinit();
    
    var total: usize = 0;
    var correctly_rejected: usize = 0;
    var incorrectly_accepted: usize = 0;
    
    const tests_obj = parsed.value.object;
    
    std.debug.print("Testing {} invalid RLP cases...\n\n", .{tests_obj.count()});
    
    var iter = tests_obj.iterator();
    while (iter.next()) |entry| {
        const test_name = entry.key_ptr.*;
        const test_case = entry.value_ptr.*.object;
        
        total += 1;
        
        // These should all have "INVALID" as input
        const in_value = test_case.get("in").?.string;
        if (!std.mem.eql(u8, in_value, "INVALID")) {
            std.debug.print("⚠️  Test {s} doesn't have INVALID marker\n", .{test_name});
            continue;
        }
        
        // Get the malformed RLP
        const out_hex = test_case.get("out").?.string;
        const malformed = try hexToBytes(allocator, out_hex[2..]);
        defer allocator.free(malformed);
        
        // Try to decode - should fail
        const decode_result = rlp.decode(malformed, allocator);
        
        if (decode_result) |decoded| {
            // BAD: We accepted invalid RLP
            incorrectly_accepted += 1;
            std.debug.print("❌ FAIL: {s} - accepted invalid RLP\n", .{test_name});
            
            // Clean up
            freeDecoded(allocator, decoded);
        } else |err| {
            // GOOD: We correctly rejected it
            correctly_rejected += 1;
            if (correctly_rejected <= 5) {
                std.debug.print("✅ PASS: {s} - correctly rejected ({s})\n", .{test_name, @errorName(err)});
            }
        }
    }
    
    std.debug.print("\n=== Invalid RLP Rejection Results ===\n", .{});
    std.debug.print("Total: {}\n", .{total});
    std.debug.print("Correctly Rejected: {} ({d:.1}%)\n", .{correctly_rejected, @as(f64, @floatFromInt(correctly_rejected)) / @as(f64, @floatFromInt(total)) * 100});
    std.debug.print("Incorrectly Accepted: {} ({d:.1}%)\n", .{incorrectly_accepted, @as(f64, @floatFromInt(incorrectly_accepted)) / @as(f64, @floatFromInt(total)) * 100});
    
    if (correctly_rejected == total) {
        std.debug.print("\n🎉 ALL INVALID RLP CORRECTLY REJECTED!\n", .{});
        std.debug.print("No crashes, no false positives. Security validated.\n", .{});
    } else {
        std.debug.print("\n⚠️  We accept some invalid RLP. Security issue.\n", .{});
    }
}

fn freeDecoded(allocator: std.mem.Allocator, decoded: rlp.Decoded) void {
    switch (decoded) {
        .bytes => {},
        .list => |l| {
            for (l) |item| {
                freeDecoded(allocator, item);
            }
            allocator.free(l);
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

