const std = @import("std");

/// Recursive Length Prefix (RLP) encoding
/// RLP is the main encoding method used to serialize objects in Ethereum

pub const RlpError = error{
    InvalidEncoding,
    BufferTooSmall,
    UnexpectedEnd,
    InvalidLength,
};

/// Encode a byte slice using RLP
pub fn encodeBytes(data: []const u8, allocator: std.mem.Allocator) ![]u8 {
    if (data.len == 1 and data[0] < 0x80) {
        // Single byte less than 128: encode as itself
        const result = try allocator.alloc(u8, 1);
        result[0] = data[0];
        return result;
    } else if (data.len < 56) {
        // 0-55 bytes: prefix with (0x80 + length)
        const result = try allocator.alloc(u8, 1 + data.len);
        result[0] = 0x80 + @as(u8, @intCast(data.len));
        @memcpy(result[1..], data);
        return result;
    } else {
        // 56+ bytes: prefix with (0xb7 + length-of-length) then length then data
        const len_bytes = lengthInBytes(data.len);
        const result = try allocator.alloc(u8, 1 + len_bytes + data.len);
        result[0] = 0xb7 + @as(u8, @intCast(len_bytes));
        
        var i: usize = len_bytes;
        var remaining = data.len;
        while (i > 0) {
            i -= 1;
            result[1 + i] = @truncate(remaining);
            remaining >>= 8;
        }
        
        @memcpy(result[1 + len_bytes ..], data);
        return result;
    }
}

/// Encode an unsigned integer
pub fn encodeU64(value: u64, allocator: std.mem.Allocator) ![]u8 {
    if (value == 0) {
        return encodeBytes(&[_]u8{}, allocator);
    }
    
    // Find minimum bytes needed
    var temp = value;
    var bytes_needed: usize = 0;
    while (temp > 0) : (temp >>= 8) {
        bytes_needed += 1;
    }
    
    var bytes = try allocator.alloc(u8, bytes_needed);
    defer allocator.free(bytes);
    
    temp = value;
    var i: usize = bytes_needed;
    while (i > 0) {
        i -= 1;
        bytes[i] = @truncate(temp);
        temp >>= 8;
    }
    
    return encodeBytes(bytes, allocator);
}

/// Encode a list of RLP-encoded items
pub fn encodeList(items: []const []const u8, allocator: std.mem.Allocator) ![]u8 {
    // Calculate total length
    var total_len: usize = 0;
    for (items) |item| {
        total_len += item.len;
    }
    
    if (total_len < 56) {
        // Short list
        const result = try allocator.alloc(u8, 1 + total_len);
        result[0] = 0xc0 + @as(u8, @intCast(total_len));
        
        var offset: usize = 1;
        for (items) |item| {
            @memcpy(result[offset..][0..item.len], item);
            offset += item.len;
        }
        
        return result;
    } else {
        // Long list
        const len_bytes = lengthInBytes(total_len);
        const result = try allocator.alloc(u8, 1 + len_bytes + total_len);
        result[0] = 0xf7 + @as(u8, @intCast(len_bytes));
        
        var i: usize = len_bytes;
        var remaining = total_len;
        while (i > 0) {
            i -= 1;
            result[1 + i] = @truncate(remaining);
            remaining >>= 8;
        }
        
        var offset: usize = 1 + len_bytes;
        for (items) |item| {
            @memcpy(result[offset..][0..item.len], item);
            offset += item.len;
        }
        
        return result;
    }
}

/// Decode RLP-encoded data with strict validation
pub const Decoded = union(enum) {
    bytes: []const u8,
    list: []const Decoded,
};

pub fn decode(data: []const u8, allocator: std.mem.Allocator) (RlpError || std.mem.Allocator.Error)!Decoded {
    if (data.len == 0) return error.UnexpectedEnd;
    
    const prefix = data[0];
    
    if (prefix < 0x80) {
        // Single byte - must be the value itself
        return Decoded{ .bytes = data[0..1] };
    } else if (prefix <= 0xb7) {
        // Short string: 0-55 bytes
        const len = prefix - 0x80;
        if (data.len < 1 + len) return error.UnexpectedEnd;
        
        // Strict validation: single byte values must not be encoded this way
        if (len == 1 and data[1] < 0x80) {
            return error.InvalidEncoding; // Should be encoded as single byte
        }
        
        return Decoded{ .bytes = data[1 .. 1 + len] };
    } else if (prefix <= 0xbf) {
        // Long string: 56+ bytes
        const len_bytes = prefix - 0xb7;
        if (len_bytes == 0) return error.InvalidLength;
        if (data.len < 1 + len_bytes) return error.UnexpectedEnd;
        
        // Strict validation: no leading zeros in length
        if (len_bytes > 1 and data[1] == 0) {
            return error.InvalidEncoding; // Leading zero in length
        }
        
        var len: usize = 0;
        for (1..1 + len_bytes) |i| {
            len = (len << 8) | data[i];
        }
        
        // Strict validation: must actually need long form
        if (len < 56) {
            return error.InvalidEncoding; // Should use short form
        }
        
        // Check for overflow before adding
        const header_size: usize = 1 + len_bytes;
        const max_payload = std.math.maxInt(usize) - header_size;
        if (len > max_payload) {
            return error.InvalidLength; // Would overflow
        }
        const total_size = header_size + len;
        
        if (data.len < total_size) return error.UnexpectedEnd;
        return Decoded{ .bytes = data[header_size..total_size] };
    } else if (prefix <= 0xf7) {
        // Short list: 0-55 bytes total
        const len = prefix - 0xc0;
        if (data.len < 1 + len) return error.UnexpectedEnd;
        
        return try decodeList(data[1 .. 1 + len], allocator);
    } else {
        // Long list: 56+ bytes total
        const len_bytes = prefix - 0xf7;
        if (len_bytes == 0) return error.InvalidLength;
        if (data.len < 1 + len_bytes) return error.UnexpectedEnd;
        
        // Strict validation: no leading zeros in length
        if (len_bytes > 1 and data[1] == 0) {
            return error.InvalidEncoding; // Leading zero in length
        }
        
        var len: usize = 0;
        for (1..1 + len_bytes) |i| {
            len = (len << 8) | data[i];
        }
        
        // Strict validation: must actually need long form  
        if (len < 56) {
            return error.InvalidEncoding; // Should use short form
        }
        
        // Check for overflow before adding
        const header_size: usize = 1 + len_bytes;
        const max_payload = std.math.maxInt(usize) - header_size;
        if (len > max_payload) {
            return error.InvalidLength; // Would overflow
        }
        const total_size = header_size + len;
        
        if (data.len < total_size) return error.UnexpectedEnd;
        return try decodeList(data[header_size..total_size], allocator);
    }
}

fn decodeList(data: []const u8, allocator: std.mem.Allocator) (RlpError || std.mem.Allocator.Error)!Decoded {
    var items = try std.ArrayList(Decoded).initCapacity(allocator, 8);
    errdefer items.deinit(allocator);
    
    var offset: usize = 0;
    while (offset < data.len) {
        // Calculate size of this item before decoding
        const item_size = try calculateRlpItemSize(data[offset..]);
        
        const item = try decode(data[offset..offset + item_size], allocator);
        try items.append(allocator, item);
        
        offset += item_size;
    }
    
    return Decoded{ .list = try items.toOwnedSlice(allocator) };
}

/// Calculate the total size of an RLP item (including prefix bytes)
fn calculateRlpItemSize(data: []const u8) !usize {
    if (data.len == 0) return error.UnexpectedEnd;
    
    const prefix = data[0];
    
    if (prefix < 0x80) {
        // Single byte
        return 1;
    } else if (prefix <= 0xb7) {
        // Short string: 1 + length
        const len = prefix - 0x80;
        return 1 + len;
    } else if (prefix <= 0xbf) {
        // Long string: 1 + len_bytes + length
        const len_bytes = prefix - 0xb7;
        if (data.len < 1 + len_bytes) return error.UnexpectedEnd;
        
        var len: usize = 0;
        for (1..1 + len_bytes) |i| {
            len = (len << 8) | data[i];
        }
        
        return 1 + len_bytes + len;
    } else if (prefix <= 0xf7) {
        // Short list: 1 + total_len
        const len = prefix - 0xc0;
        return 1 + len;
    } else {
        // Long list: 1 + len_bytes + total_len
        const len_bytes = prefix - 0xf7;
        if (data.len < 1 + len_bytes) return error.UnexpectedEnd;
        
        var len: usize = 0;
        for (1..1 + len_bytes) |i| {
            len = (len << 8) | data[i];
        }
        
        return 1 + len_bytes + len;
    }
}

fn lengthInBytes(len: usize) usize {
    if (len < 0x100) return 1;
    if (len < 0x10000) return 2;
    if (len < 0x1000000) return 3;
    if (len < 0x100000000) return 4;
    return 8;
}

test "RLP encode single byte" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    const data = [_]u8{0x42};
    const encoded = try encodeBytes(&data, allocator);
    defer allocator.free(encoded);
    
    try testing.expectEqual(@as(usize, 1), encoded.len);
    try testing.expectEqual(@as(u8, 0x42), encoded[0]);
}

test "RLP encode short string" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    const data = "dog";
    const encoded = try encodeBytes(data, allocator);
    defer allocator.free(encoded);
    
    try testing.expectEqual(@as(u8, 0x83), encoded[0]);
    try testing.expectEqualStrings("dog", encoded[1..]);
}

test "RLP encode integer" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    const encoded = try encodeU64(15, allocator);
    defer allocator.free(encoded);
    
    try testing.expectEqual(@as(u8, 0x0f), encoded[0]);
}

test "RLP encode empty string" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    const encoded = try encodeBytes(&[_]u8{}, allocator);
    defer allocator.free(encoded);
    
    try testing.expectEqual(@as(usize, 1), encoded.len);
    try testing.expectEqual(@as(u8, 0x80), encoded[0]);
}

