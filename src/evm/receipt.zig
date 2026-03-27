const std = @import("std");
const types = @import("types");
const crypto = @import("crypto");
const evm = @import("evm");
const transaction = @import("transaction");
const rlp = @import("rlp");

/// EIP-658 transaction receipt with EIP-7 log bloom filter.
pub const Receipt = struct {
    tx_type: transaction.TransactionType,
    status: bool, // EIP-658: true = success
    cumulative_gas_used: u64, // total gas used up to and including this tx in the block
    logs_bloom: [256]u8, // EIP-7: 2048-bit bloom filter (256 bytes)
    logs: []const evm.Log,

    /// EIP-2718 typed receipt RLP encoding.
    ///
    /// Legacy receipts are bare RLP lists.
    /// Typed receipts (EIP-2930, EIP-1559) are prefixed with a single type byte
    /// before the RLP list, per EIP-2718.
    ///
    /// Receipt list: [status, cumulativeGasUsed, logsBloom, logs]
    /// Each log:     [address, topics, data]
    pub fn encode(self: Receipt, allocator: std.mem.Allocator) ![]u8 {
        // Encode status: 0x01 for success, 0x80 (empty string) for failure.
        const status_encoded = try rlp.encodeBytes(
            if (self.status) &[_]u8{0x01} else &[_]u8{},
            allocator,
        );
        defer allocator.free(status_encoded);

        // Encode cumulative gas used
        const gas_encoded = try rlp.encodeU64(self.cumulative_gas_used, allocator);
        defer allocator.free(gas_encoded);

        // Encode logs bloom (always 256 bytes)
        const bloom_encoded = try rlp.encodeBytes(&self.logs_bloom, allocator);
        defer allocator.free(bloom_encoded);

        // Encode logs list
        var log_items = std.ArrayList([]const u8).init(allocator);
        defer {
            for (log_items.items) |item| allocator.free(item);
            log_items.deinit();
        }

        for (self.logs) |log| {
            const encoded_log = try encodeLog(log, allocator);
            try log_items.append(encoded_log);
        }

        const logs_encoded = try rlp.encodeList(log_items.items, allocator);
        defer allocator.free(logs_encoded);

        // Build the receipt list: [status, cumulativeGasUsed, logsBloom, logs]
        const receipt_items = [_][]const u8{
            status_encoded,
            gas_encoded,
            bloom_encoded,
            logs_encoded,
        };

        const receipt_rlp = try rlp.encodeList(&receipt_items, allocator);

        // For typed transactions, prepend the type byte
        switch (self.tx_type) {
            .legacy => return receipt_rlp,
            .access_list, .dynamic_fee, .blob => {
                const typed = try allocator.alloc(u8, 1 + receipt_rlp.len);
                typed[0] = @intFromEnum(self.tx_type);
                @memcpy(typed[1..], receipt_rlp);
                allocator.free(receipt_rlp);
                return typed;
            },
        }
    }
};

/// RLP-encode a single log entry as [address, [topic0, topic1, ...], data].
fn encodeLog(log: evm.Log, allocator: std.mem.Allocator) ![]u8 {
    // Encode address (20 bytes)
    const addr_encoded = try rlp.encodeBytes(&log.address.bytes, allocator);
    defer allocator.free(addr_encoded);

    // Encode topics list
    var topic_items = std.ArrayList([]const u8).init(allocator);
    defer {
        for (topic_items.items) |item| allocator.free(item);
        topic_items.deinit();
    }

    for (log.topics) |topic| {
        const encoded_topic = try rlp.encodeBytes(&topic.bytes, allocator);
        try topic_items.append(encoded_topic);
    }

    const topics_encoded = try rlp.encodeList(topic_items.items, allocator);
    defer allocator.free(topics_encoded);

    // Encode data
    const data_encoded = try rlp.encodeBytes(log.data, allocator);
    defer allocator.free(data_encoded);

    // Build the log list: [address, topics, data]
    const log_items = [_][]const u8{
        addr_encoded,
        topics_encoded,
        data_encoded,
    };

    return rlp.encodeList(&log_items, allocator);
}

// ---------------------------------------------------------------------------
// EIP-7 Log Bloom Filter
// ---------------------------------------------------------------------------

/// Build a 2048-bit bloom filter for a single log entry (address + topics).
pub fn bloomForLog(log: evm.Log) [256]u8 {
    var bloom: [256]u8 = [_]u8{0} ** 256;
    // Add log address (20 bytes)
    bloomInsert(&bloom, &log.address.bytes);
    // Add each topic (32 bytes each)
    for (log.topics) |topic| {
        bloomInsert(&bloom, &topic.bytes);
    }
    return bloom;
}

/// Insert a single value into the bloom filter.
///
/// Hash the value with keccak256, then for each of the first three pairs
/// of bytes in the hash, extract the low 11 bits as an index into the
/// 2048-bit array and set that bit.
fn bloomInsert(bloom: *[256]u8, data: []const u8) void {
    var hash: [32]u8 = undefined;
    crypto.keccak256(data, &hash);
    for (0..3) |i| {
        // Take pairs of bytes from the hash, extract 11-bit index
        const bit_index: u16 = (@as(u16, hash[i * 2]) << 8 | hash[i * 2 + 1]) & 0x7FF;
        const byte_index = bit_index / 8;
        const bit_position: u3 = @intCast(bit_index % 8);
        bloom[byte_index] |= @as(u8, 1) << bit_position;
    }
}

/// Build a 2048-bit bloom filter from all logs in a transaction/block.
/// The result is the bitwise OR of individual log blooms.
pub fn logsBloom(logs: []const evm.Log) [256]u8 {
    var bloom: [256]u8 = [_]u8{0} ** 256;
    for (logs) |log| {
        const log_bloom = bloomForLog(log);
        for (0..256) |i| bloom[i] |= log_bloom[i];
    }
    return bloom;
}

/// Construct a Receipt from a TransactionResult and its originating transaction.
pub fn fromTransactionResult(
    result: transaction.TransactionResult,
    tx: transaction.Transaction,
    cumulative_gas: u64,
) Receipt {
    return .{
        .tx_type = tx.tx_type,
        .status = result.success,
        .cumulative_gas_used = cumulative_gas,
        .logs_bloom = logsBloom(result.logs),
        .logs = result.logs,
    };
}

// ===========================================================================
// Tests
// ===========================================================================

fn makeAddress(byte19: u8) types.Address {
    var addr = types.Address.zero;
    addr.bytes[19] = byte19;
    return addr;
}

fn makeHash(fill: u8) types.Hash {
    return types.Hash{ .bytes = [_]u8{fill} ** 32 };
}

fn isAllZero(data: []const u8) bool {
    for (data) |b| {
        if (b != 0) return false;
    }
    return true;
}

fn countSetBits(data: []const u8) u32 {
    var count: u32 = 0;
    for (data) |b| {
        count += @popCount(b);
    }
    return count;
}

// ---- Test 1: Empty bloom for no logs ----
test "empty bloom for no logs" {
    const empty_logs: []const evm.Log = &[_]evm.Log{};
    const bloom = logsBloom(empty_logs);
    try std.testing.expect(isAllZero(&bloom));
}

// ---- Test 2: Bloom for single log with address only ----
test "bloom for single log with address only (no topics)" {
    const addr = makeAddress(0xAA);
    const log = evm.Log{
        .address = addr,
        .topics = &[_]types.Hash{},
        .data = &[_]u8{},
    };

    const bloom = bloomForLog(log);

    // The bloom must have some bits set (address contributes 3 bits)
    try std.testing.expect(!isAllZero(&bloom));
    // keccak256 of the 20-byte address sets exactly 3 bit positions
    // (some may collide, so between 1 and 3 unique bits)
    const bits = countSetBits(&bloom);
    try std.testing.expect(bits >= 1 and bits <= 3);
}

// ---- Test 3: Bloom for log with topics ----
test "bloom for log with topics" {
    const addr = makeAddress(0xBB);
    var topics = [_]types.Hash{
        makeHash(0x01),
        makeHash(0x02),
    };
    const log = evm.Log{
        .address = addr,
        .topics = &topics,
        .data = &[_]u8{ 0xDE, 0xAD },
    };

    const bloom = bloomForLog(log);

    // Address contributes 3 bit positions, each topic contributes 3 more.
    // Total inputs: 3 (1 address + 2 topics), so up to 9 bits set (with possible collisions).
    try std.testing.expect(!isAllZero(&bloom));
    const bits = countSetBits(&bloom);
    // At minimum 1 bit, at maximum 9 bits (3 inputs * 3 bit positions each)
    try std.testing.expect(bits >= 1 and bits <= 9);
}

// ---- Test 4: Bloom aggregation across multiple logs ----
test "bloom aggregation across multiple logs" {
    const log1 = evm.Log{
        .address = makeAddress(0x01),
        .topics = &[_]types.Hash{},
        .data = &[_]u8{},
    };
    const log2 = evm.Log{
        .address = makeAddress(0x02),
        .topics = &[_]types.Hash{},
        .data = &[_]u8{},
    };

    const bloom1 = bloomForLog(log1);
    const bloom2 = bloomForLog(log2);

    const logs = [_]evm.Log{ log1, log2 };
    const combined = logsBloom(&logs);

    // Combined bloom must be a superset of each individual bloom (bitwise OR)
    for (0..256) |i| {
        try std.testing.expectEqual(bloom1[i] | bloom2[i], combined[i]);
    }
}

// ---- Test 5: Bloom bit positions match known keccak256 derivation ----
test "bloom bit positions match known keccak256 derivation" {
    // We manually compute the expected bit positions for a known input.
    // Input: 20-byte zero address (all zeros).
    const data = [_]u8{0} ** 20;
    var hash: [32]u8 = undefined;
    crypto.keccak256(&data, &hash);

    // Extract the three 11-bit indices the same way bloomInsert does.
    var expected_bloom: [256]u8 = [_]u8{0} ** 256;
    for (0..3) |i| {
        const bit_index: u16 = (@as(u16, hash[i * 2]) << 8 | hash[i * 2 + 1]) & 0x7FF;
        const byte_index = bit_index / 8;
        const bit_position: u3 = @intCast(bit_index % 8);
        expected_bloom[byte_index] |= @as(u8, 1) << bit_position;
    }

    // Now build the bloom via the public API
    const log = evm.Log{
        .address = types.Address.zero,
        .topics = &[_]types.Hash{},
        .data = &[_]u8{},
    };
    const actual_bloom = bloomForLog(log);

    try std.testing.expectEqualSlices(u8, &expected_bloom, &actual_bloom);
}

// ---- Test 6: Receipt creation from successful tx ----
test "receipt from successful transaction" {
    var topics = [_]types.Hash{makeHash(0xFF)};
    const log = evm.Log{
        .address = makeAddress(0xCC),
        .topics = &topics,
        .data = &[_]u8{0x42},
    };
    const logs = [_]evm.Log{log};

    const result = transaction.TransactionResult{
        .success = true,
        .gas_used = 50_000,
        .gas_refund = 0,
        .return_data = &[_]u8{},
        .logs = &logs,
        .created_address = null,
    };

    const tx = transaction.Transaction{
        .tx_type = .legacy,
        .nonce = 0,
        .gas_limit = 100_000,
        .to = makeAddress(0xDD),
        .value = types.U256.zero(),
        .data = &[_]u8{},
        .gas_price = 1,
        .from = makeAddress(0xAA),
    };

    const receipt = fromTransactionResult(result, tx, 50_000);

    try std.testing.expect(receipt.status);
    try std.testing.expectEqual(@as(u64, 50_000), receipt.cumulative_gas_used);
    try std.testing.expectEqual(transaction.TransactionType.legacy, receipt.tx_type);
    try std.testing.expectEqual(@as(usize, 1), receipt.logs.len);
    // Bloom must be non-zero since we have a log
    try std.testing.expect(!isAllZero(&receipt.logs_bloom));
}

// ---- Test 7: Receipt creation from failed tx (empty logs) ----
test "receipt from failed transaction has empty bloom" {
    const result = transaction.TransactionResult{
        .success = false,
        .gas_used = 21_000,
        .gas_refund = 0,
        .return_data = &[_]u8{},
        .logs = &[_]evm.Log{},
        .created_address = null,
    };

    const tx = transaction.Transaction{
        .tx_type = .dynamic_fee,
        .nonce = 5,
        .gas_limit = 21_000,
        .to = makeAddress(0xEE),
        .value = types.U256.zero(),
        .data = &[_]u8{},
        .max_fee_per_gas = 30,
        .max_priority_fee_per_gas = 5,
        .from = makeAddress(0xAA),
    };

    const receipt = fromTransactionResult(result, tx, 100_000);

    try std.testing.expect(!receipt.status);
    try std.testing.expectEqual(@as(u64, 100_000), receipt.cumulative_gas_used);
    try std.testing.expectEqual(transaction.TransactionType.dynamic_fee, receipt.tx_type);
    try std.testing.expectEqual(@as(usize, 0), receipt.logs.len);
    try std.testing.expect(isAllZero(&receipt.logs_bloom));
}

// ---- Test 8: Bloom insert is idempotent ----
test "bloom insert is idempotent" {
    const addr = makeAddress(0x42);
    var topics = [_]types.Hash{makeHash(0xAB)};
    const log = evm.Log{
        .address = addr,
        .topics = &topics,
        .data = &[_]u8{},
    };

    const bloom_once = bloomForLog(log);

    // Manually insert the same data twice into a bloom
    var bloom_twice: [256]u8 = [_]u8{0} ** 256;
    bloomInsert(&bloom_twice, &addr.bytes);
    bloomInsert(&bloom_twice, &addr.bytes); // second insert of same data
    bloomInsert(&bloom_twice, &topics[0].bytes);
    bloomInsert(&bloom_twice, &topics[0].bytes); // second insert of same data

    try std.testing.expectEqualSlices(u8, &bloom_once, &bloom_twice);
}

// ---- Test 9: Receipt RLP encoding roundtrip (legacy) ----
test "receipt encode produces valid RLP for legacy tx" {
    const allocator = std.testing.allocator;

    const receipt = Receipt{
        .tx_type = .legacy,
        .status = true,
        .cumulative_gas_used = 21_000,
        .logs_bloom = [_]u8{0} ** 256,
        .logs = &[_]evm.Log{},
    };

    const encoded = try receipt.encode(allocator);
    defer allocator.free(encoded);

    // Legacy receipt is a bare RLP list (no type prefix).
    // First byte should be an RLP list marker (>= 0xc0).
    // The payload is >= 256 bytes (bloom alone), so it will be a long list (>= 0xf8).
    try std.testing.expect(encoded[0] >= 0xf8);
    try std.testing.expect(encoded.len > 256);
}

// ---- Test 10: Receipt RLP encoding for typed tx has type prefix ----
test "receipt encode for EIP-1559 tx has type byte prefix" {
    const allocator = std.testing.allocator;

    const receipt = Receipt{
        .tx_type = .dynamic_fee,
        .status = false,
        .cumulative_gas_used = 42_000,
        .logs_bloom = [_]u8{0} ** 256,
        .logs = &[_]evm.Log{},
    };

    const encoded = try receipt.encode(allocator);
    defer allocator.free(encoded);

    // Typed receipt: first byte is the type byte (0x02 for dynamic_fee)
    try std.testing.expectEqual(@as(u8, 0x02), encoded[0]);
    // Second byte should be RLP list marker
    try std.testing.expect(encoded[1] >= 0xf8);
}

// ---- Test 11: Receipt encoding with logs ----
test "receipt encode includes log data" {
    const allocator = std.testing.allocator;

    var topics = [_]types.Hash{makeHash(0x01)};
    const log = evm.Log{
        .address = makeAddress(0xAA),
        .topics = &topics,
        .data = &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF },
    };
    const logs = [_]evm.Log{log};

    const receipt = Receipt{
        .tx_type = .access_list,
        .status = true,
        .cumulative_gas_used = 63_000,
        .logs_bloom = bloomForLog(log),
        .logs = &logs,
    };

    const encoded = try receipt.encode(allocator);
    defer allocator.free(encoded);

    // Type prefix for access_list = 0x01
    try std.testing.expectEqual(@as(u8, 0x01), encoded[0]);
    // Encoded receipt must be larger than one without logs
    try std.testing.expect(encoded.len > 260);
}
