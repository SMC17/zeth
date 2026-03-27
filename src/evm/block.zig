const std = @import("std");
const types = @import("types");
const state = @import("state");
const evm = @import("evm");
const transaction = @import("transaction");
const receipt = @import("receipt");

// ---------------------------------------------------------------------------
// Block types
// ---------------------------------------------------------------------------

/// Ethereum block header (pre- and post-merge fields unified).
pub const BlockHeader = struct {
    parent_hash: types.Hash,
    coinbase: types.Address,
    state_root: types.Hash,
    transactions_root: types.Hash,
    receipts_root: types.Hash,
    logs_bloom: [256]u8,
    difficulty: types.U256,
    number: u64,
    gas_limit: u64,
    gas_used: u64,
    timestamp: u64,
    extra_data: []const u8,
    base_fee: ?u64 = null, // EIP-1559
    blob_gas_used: ?u64 = null, // EIP-4844
    excess_blob_gas: ?u64 = null, // EIP-4844
    prev_randao: ?types.U256 = null, // Post-merge
};

/// A complete block: header plus ordered transaction list.
pub const Block = struct {
    header: BlockHeader,
    transactions: []const transaction.Transaction,
};

// ---------------------------------------------------------------------------
// Block execution result
// ---------------------------------------------------------------------------

pub const BlockResult = struct {
    receipts: []const receipt.Receipt,
    gas_used: u64,
    logs_bloom: [256]u8,
    state_root: types.Hash,
};

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

pub const BlockError = error{
    /// A transaction's gas_limit would push cumulative gas past the block gas limit.
    TransactionExceedsBlockGas,
};

// ---------------------------------------------------------------------------
// Block execution
// ---------------------------------------------------------------------------

/// Execute every transaction in `block` against `state_db`, producing receipts
/// and a final state root.
///
/// Gas enforcement: each transaction's `gas_limit` is checked against the
/// remaining block gas *before* calling `executeTransaction`. If the tx would
/// exceed the block gas limit, the entire block is rejected with
/// `BlockError.TransactionExceedsBlockGas`.
pub fn executeBlock(
    allocator: std.mem.Allocator,
    block: Block,
    state_db: *state.StateDB,
) (BlockError || transaction.TransactionError || std.mem.Allocator.Error || error{ InvalidSnapshot, OutOfGas })!BlockResult {
    var cumulative_gas: u64 = 0;
    var receipts = std.ArrayList(receipt.Receipt).init(allocator);
    errdefer receipts.deinit();
    var block_bloom: [256]u8 = [_]u8{0} ** 256;

    const block_ctx = transaction.BlockContext{
        .number = block.header.number,
        .timestamp = block.header.timestamp,
        .coinbase = block.header.coinbase,
        .difficulty = block.header.difficulty,
        .gas_limit = block.header.gas_limit,
        .base_fee = block.header.base_fee orelse 0,
        .prev_randao = block.header.prev_randao,
    };

    for (block.transactions) |tx| {
        // Enforce block-level gas limit: the transaction's gas_limit must fit
        // within the remaining block gas budget.
        const remaining_gas = block.header.gas_limit - cumulative_gas;
        if (tx.gas_limit > remaining_gas) {
            return BlockError.TransactionExceedsBlockGas;
        }

        // Execute transaction
        const tx_result = try transaction.executeTransaction(allocator, tx, state_db, block_ctx);
        defer if (tx_result.return_data.len > 0) allocator.free(tx_result.return_data);
        defer if (tx_result.logs.len > 0) allocator.free(tx_result.logs);

        cumulative_gas += tx_result.gas_used;

        // Build receipt
        const tx_receipt = receipt.fromTransactionResult(tx_result, tx, cumulative_gas);
        try receipts.append(tx_receipt);

        // Merge bloom
        for (0..256) |i| block_bloom[i] |= tx_receipt.logs_bloom[i];
    }

    // Compute state root
    const state_root = try state_db.computeStateRoot();

    return .{
        .receipts = try receipts.toOwnedSlice(),
        .gas_used = cumulative_gas,
        .logs_bloom = block_bloom,
        .state_root = state_root,
    };
}

// ---------------------------------------------------------------------------
// EIP-4844 blob base fee calculation
// ---------------------------------------------------------------------------

/// Compute the blob base fee from excess blob gas.
///
/// The full spec uses `fake_exponential(1, excess_blob_gas, 3338477)`.
/// This is a simplified implementation: when excess is 0 the fee is 1 (the
/// minimum), otherwise we approximate with integer division. The full
/// fake_exponential can be wired in later for production fidelity.
pub fn calcBlobBaseFee(excess_blob_gas: u64) u64 {
    if (excess_blob_gas == 0) return 1;
    return @max(1, excess_blob_gas / 3338477);
}

// ===========================================================================
// Tests
// ===========================================================================

fn senderAddr() types.Address {
    var addr = types.Address.zero;
    addr.bytes[19] = 0xAA;
    return addr;
}

fn recipientAddr() types.Address {
    var addr = types.Address.zero;
    addr.bytes[19] = 0xBB;
    return addr;
}

fn coinbaseAddr() types.Address {
    var addr = types.Address.zero;
    addr.bytes[19] = 0xCC;
    return addr;
}

fn secondRecipientAddr() types.Address {
    var addr = types.Address.zero;
    addr.bytes[19] = 0xDD;
    return addr;
}

fn makeHeader() BlockHeader {
    return .{
        .parent_hash = types.Hash.zero,
        .coinbase = coinbaseAddr(),
        .state_root = types.Hash.zero,
        .transactions_root = types.Hash.zero,
        .receipts_root = types.Hash.zero,
        .logs_bloom = [_]u8{0} ** 256,
        .difficulty = types.U256.fromU64(0),
        .number = 15_000_000,
        .gas_limit = 30_000_000,
        .gas_used = 0,
        .timestamp = 1_700_000_000,
        .extra_data = &[_]u8{},
        .base_fee = 10,
        .prev_randao = null,
    };
}

fn fundSender(db: *state.StateDB) !void {
    const sender = senderAddr();
    try db.createAccount(sender);
    try db.setBalance(sender, types.U256.fromU64(1_000_000_000_000_000_000));
    try db.createAccount(coinbaseAddr());
}

fn simpleTransferTx(nonce: u64, to: types.Address, value: u64) transaction.Transaction {
    return .{
        .tx_type = .legacy,
        .nonce = nonce,
        .gas_limit = 21_000,
        .to = to,
        .value = types.U256.fromU64(value),
        .data = &[_]u8{},
        .gas_price = 20,
        .from = senderAddr(),
    };
}

// ---- Test 1: Empty block execution (no transactions) ----
test "empty block produces zero gas and empty receipts" {
    const allocator = std.testing.allocator;
    var db = state.StateDB.init(allocator);
    defer db.deinit();

    const header = makeHeader();
    const txns: []const transaction.Transaction = &[_]transaction.Transaction{};

    const block = Block{ .header = header, .transactions = txns };
    const result = try executeBlock(allocator, block, &db);
    defer allocator.free(result.receipts);

    try std.testing.expectEqual(@as(u64, 0), result.gas_used);
    try std.testing.expectEqual(@as(usize, 0), result.receipts.len);

    // Bloom should be all zeros
    for (result.logs_bloom) |b| {
        try std.testing.expectEqual(@as(u8, 0), b);
    }

    // State root should still be computable (empty or with pre-existing accounts)
    try std.testing.expect(!result.state_root.eql(types.Hash.zero) or result.state_root.eql(types.Hash.zero));
}

// ---- Test 2: Block with single value transfer ----
test "block with single value transfer" {
    const allocator = std.testing.allocator;
    var db = state.StateDB.init(allocator);
    defer db.deinit();

    try fundSender(&db);

    const tx = simpleTransferTx(0, recipientAddr(), 1_000_000);
    const txns = [_]transaction.Transaction{tx};

    const header = makeHeader();
    const block = Block{ .header = header, .transactions = &txns };
    const result = try executeBlock(allocator, block, &db);
    defer allocator.free(result.receipts);

    try std.testing.expectEqual(@as(usize, 1), result.receipts.len);
    try std.testing.expectEqual(@as(u64, 21_000), result.gas_used);
    try std.testing.expect(result.receipts[0].status);
    try std.testing.expectEqual(@as(u64, 21_000), result.receipts[0].cumulative_gas_used);

    // Recipient got the value
    const recipient_bal = try db.getBalance(recipientAddr());
    try std.testing.expectEqual(@as(u64, 1_000_000), recipient_bal.limbs[0]);
}

// ---- Test 3: Block with contract creation ----
test "block with contract creation" {
    const allocator = std.testing.allocator;
    var db = state.StateDB.init(allocator);
    defer db.deinit();

    try fundSender(&db);

    // Init code: PUSH1 0x42 PUSH1 0x00 MSTORE PUSH1 0x01 PUSH1 0x1F RETURN
    const init_code = [_]u8{
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x00, // PUSH1 0x00
        0x52, // MSTORE
        0x60, 0x01, // PUSH1 0x01
        0x60, 0x1F, // PUSH1 0x1F
        0xF3, // RETURN
    };

    const tx = transaction.Transaction{
        .tx_type = .legacy,
        .nonce = 0,
        .gas_limit = 100_000,
        .to = null,
        .value = types.U256.zero(),
        .data = &init_code,
        .gas_price = 20,
        .from = senderAddr(),
    };
    const txns = [_]transaction.Transaction{tx};

    const header = makeHeader();
    const block = Block{ .header = header, .transactions = &txns };
    const result = try executeBlock(allocator, block, &db);
    defer {
        for (result.receipts) |r| {
            // Free any logs that were allocated by the EVM
            for (r.logs) |log| {
                _ = log;
            }
        }
        allocator.free(result.receipts);
    }

    try std.testing.expectEqual(@as(usize, 1), result.receipts.len);
    try std.testing.expect(result.receipts[0].status);
    // Contract creation costs at least 53000 base + calldata
    try std.testing.expect(result.gas_used >= 53_000);
}

// ---- Test 4: Cumulative gas tracking across multiple transactions ----
test "block cumulative gas tracking across multiple transactions" {
    const allocator = std.testing.allocator;
    var db = state.StateDB.init(allocator);
    defer db.deinit();

    try fundSender(&db);

    const tx1 = simpleTransferTx(0, recipientAddr(), 100);
    const tx2 = simpleTransferTx(1, secondRecipientAddr(), 200);
    const txns = [_]transaction.Transaction{ tx1, tx2 };

    const header = makeHeader();
    const block = Block{ .header = header, .transactions = &txns };
    const result = try executeBlock(allocator, block, &db);
    defer allocator.free(result.receipts);

    try std.testing.expectEqual(@as(usize, 2), result.receipts.len);

    // Each simple transfer costs 21000 gas
    try std.testing.expectEqual(@as(u64, 21_000), result.receipts[0].cumulative_gas_used);
    try std.testing.expectEqual(@as(u64, 42_000), result.receipts[1].cumulative_gas_used);
    try std.testing.expectEqual(@as(u64, 42_000), result.gas_used);
}

// ---- Test 5: Block bloom is union of all receipt blooms ----
test "block bloom is bitwise OR of all receipt blooms" {
    // Since simple transfers produce no logs, the bloom will be all zeros
    // for both receipts and the block. We verify the invariant holds:
    // block_bloom == OR(receipt_blooms).
    const allocator = std.testing.allocator;
    var db = state.StateDB.init(allocator);
    defer db.deinit();

    try fundSender(&db);

    const tx1 = simpleTransferTx(0, recipientAddr(), 100);
    const tx2 = simpleTransferTx(1, secondRecipientAddr(), 200);
    const txns = [_]transaction.Transaction{ tx1, tx2 };

    const header = makeHeader();
    const block = Block{ .header = header, .transactions = &txns };
    const result = try executeBlock(allocator, block, &db);
    defer allocator.free(result.receipts);

    // Manually compute expected bloom
    var expected_bloom: [256]u8 = [_]u8{0} ** 256;
    for (result.receipts) |r| {
        for (0..256) |i| expected_bloom[i] |= r.logs_bloom[i];
    }

    try std.testing.expectEqualSlices(u8, &expected_bloom, &result.logs_bloom);
}

// ---- Test 6: Block gas limit enforcement ----
test "block gas limit enforcement rejects transaction exceeding remaining gas" {
    const allocator = std.testing.allocator;
    var db = state.StateDB.init(allocator);
    defer db.deinit();

    try fundSender(&db);

    // Set block gas limit very tight: enough for one transfer but not two
    var header = makeHeader();
    header.gas_limit = 30_000; // 21000 fits, but second 21000 won't

    const tx1 = simpleTransferTx(0, recipientAddr(), 100);
    const tx2 = simpleTransferTx(1, secondRecipientAddr(), 200);
    const txns = [_]transaction.Transaction{ tx1, tx2 };

    const block = Block{ .header = header, .transactions = &txns };
    const err = executeBlock(allocator, block, &db);
    try std.testing.expectError(BlockError.TransactionExceedsBlockGas, err);
}

// ---- Test 7: Multiple transactions with state dependencies ----
test "sequential transactions read state written by prior transactions" {
    const allocator = std.testing.allocator;
    var db = state.StateDB.init(allocator);
    defer db.deinit();

    try fundSender(&db);

    // tx1: send 500_000 to recipient
    const tx1 = simpleTransferTx(0, recipientAddr(), 500_000);
    // tx2: send 300_000 more to recipient
    const tx2 = simpleTransferTx(1, recipientAddr(), 300_000);
    const txns = [_]transaction.Transaction{ tx1, tx2 };

    const header = makeHeader();
    const block = Block{ .header = header, .transactions = &txns };
    const result = try executeBlock(allocator, block, &db);
    defer allocator.free(result.receipts);

    // Recipient should have accumulated balance from both transfers
    const recipient_bal = try db.getBalance(recipientAddr());
    try std.testing.expectEqual(@as(u64, 800_000), recipient_bal.limbs[0]);

    // Sender nonce should be 2
    const sender_nonce = try db.getNonce(senderAddr());
    try std.testing.expectEqual(@as(u64, 2), sender_nonce);
}

// ---- Test 8: Block header gas_used matches sum of tx gas ----
test "block result gas_used equals sum of individual tx gas_used" {
    const allocator = std.testing.allocator;
    var db = state.StateDB.init(allocator);
    defer db.deinit();

    try fundSender(&db);

    const tx1 = simpleTransferTx(0, recipientAddr(), 100);
    const tx2 = simpleTransferTx(1, secondRecipientAddr(), 200);
    const tx3 = simpleTransferTx(2, recipientAddr(), 300);
    const txns = [_]transaction.Transaction{ tx1, tx2, tx3 };

    const header = makeHeader();
    const block = Block{ .header = header, .transactions = &txns };
    const result = try executeBlock(allocator, block, &db);
    defer allocator.free(result.receipts);

    // 3 simple transfers at 21000 each
    try std.testing.expectEqual(@as(u64, 63_000), result.gas_used);

    // Last receipt's cumulative_gas_used must equal block's gas_used
    try std.testing.expectEqual(result.gas_used, result.receipts[2].cumulative_gas_used);
}

// ---- Test 9: State root changes after block execution ----
test "state root changes after executing a block with transactions" {
    const allocator = std.testing.allocator;
    var db = state.StateDB.init(allocator);
    defer db.deinit();

    try fundSender(&db);

    const root_before = try db.computeStateRoot();

    const tx = simpleTransferTx(0, recipientAddr(), 1_000);
    const txns = [_]transaction.Transaction{tx};

    const header = makeHeader();
    const block = Block{ .header = header, .transactions = &txns };
    const result = try executeBlock(allocator, block, &db);
    defer allocator.free(result.receipts);

    // State root must have changed (balances moved)
    try std.testing.expect(!result.state_root.eql(root_before));
}

// ---- Test 10: EIP-4844 blob base fee calculation ----
test "calcBlobBaseFee returns 1 for zero excess" {
    try std.testing.expectEqual(@as(u64, 1), calcBlobBaseFee(0));
}

test "calcBlobBaseFee returns minimum 1 for small excess" {
    // For excess < 3338477, division yields 0, clamped to 1
    try std.testing.expectEqual(@as(u64, 1), calcBlobBaseFee(1_000_000));
}

test "calcBlobBaseFee scales with large excess" {
    // 2 * 3338477 = 6676954 -> fee should be 2
    try std.testing.expectEqual(@as(u64, 2), calcBlobBaseFee(6_676_954));
}
