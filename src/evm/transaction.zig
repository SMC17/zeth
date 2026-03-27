const std = @import("std");
const types = @import("types");
const state = @import("state");
const evm = @import("evm");
const crypto = @import("crypto");

/// EIP-2718 transaction type envelope.
pub const TransactionType = enum(u8) {
    legacy = 0,
    access_list = 1, // EIP-2930
    dynamic_fee = 2, // EIP-1559
};

/// Ethereum transaction (all types unified).
pub const Transaction = struct {
    tx_type: TransactionType = .legacy,
    nonce: u64,
    gas_limit: u64,
    to: ?types.Address, // null = contract creation
    value: types.U256,
    data: []const u8,

    // Legacy / EIP-2930
    gas_price: ?u64 = null,

    // EIP-1559
    max_fee_per_gas: ?u64 = null,
    max_priority_fee_per_gas: ?u64 = null,

    // EIP-2930
    access_list: ?[]const AccessListEntry = null,

    // Sender (recovered from signature in practice; explicit here)
    from: types.Address,
    chain_id: u64 = 1,
};

/// EIP-2930 access list entry.
pub const AccessListEntry = struct {
    address: types.Address,
    storage_keys: []const types.U256,
};

/// Block environment supplied by the consensus layer.
pub const BlockContext = struct {
    number: u64,
    timestamp: u64,
    coinbase: types.Address,
    difficulty: types.U256,
    gas_limit: u64,
    base_fee: u64,
    prev_randao: ?types.U256 = null,
    chain_id: u64 = 1,
};

/// Result of executing a single transaction against state.
pub const TransactionResult = struct {
    success: bool,
    gas_used: u64,
    gas_refund: u64,
    return_data: []const u8,
    logs: []const evm.Log,
    created_address: ?types.Address,
};

/// Transaction validation/execution errors.
pub const TransactionError = error{
    NonceMismatch,
    InsufficientBalance,
    GasLimitExceedsBlock,
    MaxFeeUnderBaseFee,
    IntrinsicGasExceedsLimit,
    MissingGasPrice,
};

// ---------------------------------------------------------------------------
// Intrinsic gas (EIP-2028, EIP-2930, EIP-3860)
// ---------------------------------------------------------------------------

const TX_GAS_BASE: u64 = 21_000;
const TX_GAS_CREATE: u64 = 53_000;
const TX_DATA_ZERO_GAS: u64 = 4;
const TX_DATA_NONZERO_GAS: u64 = 16;
const TX_ACCESS_LIST_ADDRESS_GAS: u64 = 2_400;
const TX_ACCESS_LIST_STORAGE_KEY_GAS: u64 = 1_900;

pub fn intrinsicGas(tx: Transaction) u64 {
    var gas: u64 = if (tx.to == null) TX_GAS_CREATE else TX_GAS_BASE;

    for (tx.data) |byte| {
        gas += if (byte == 0) TX_DATA_ZERO_GAS else TX_DATA_NONZERO_GAS;
    }

    if (tx.access_list) |al| {
        for (al) |entry| {
            gas += TX_ACCESS_LIST_ADDRESS_GAS;
            gas += TX_ACCESS_LIST_STORAGE_KEY_GAS * @as(u64, @intCast(entry.storage_keys.len));
        }
    }

    return gas;
}

// ---------------------------------------------------------------------------
// Effective gas price helpers (EIP-1559)
// ---------------------------------------------------------------------------

fn effectiveGasPrice(tx: Transaction, base_fee: u64) !u64 {
    return switch (tx.tx_type) {
        .legacy, .access_list => tx.gas_price orelse return TransactionError.MissingGasPrice,
        .dynamic_fee => blk: {
            const max_fee = tx.max_fee_per_gas orelse return TransactionError.MissingGasPrice;
            const max_priority = tx.max_priority_fee_per_gas orelse 0;
            // effective_gas_price = min(max_fee, base_fee + max_priority)
            const fee = @min(max_fee, base_fee + max_priority);
            break :blk fee;
        },
    };
}

// ---------------------------------------------------------------------------
// Contract address derivation (CREATE via transaction)
// ---------------------------------------------------------------------------

fn deriveCreateAddress(sender: types.Address, nonce: u64) types.Address {
    var preimage: [28]u8 = undefined;
    @memcpy(preimage[0..20], sender.bytes[0..20]);
    std.mem.writeInt(u64, preimage[20..28], nonce, .big);
    var hash: [32]u8 = undefined;
    crypto.keccak256(&preimage, &hash);
    var address_bytes: [20]u8 = undefined;
    @memcpy(&address_bytes, hash[12..32]);
    return types.Address{ .bytes = address_bytes };
}

// ---------------------------------------------------------------------------
// Transaction execution
// ---------------------------------------------------------------------------

pub fn executeTransaction(
    allocator: std.mem.Allocator,
    tx: Transaction,
    state_db: *state.StateDB,
    block: BlockContext,
) (TransactionError || std.mem.Allocator.Error || error{ InvalidSnapshot, OutOfGas })!TransactionResult {
    // 1. Validate nonce
    const sender_nonce = try state_db.getNonce(tx.from);
    if (sender_nonce != tx.nonce) return TransactionError.NonceMismatch;

    // 2. Calculate intrinsic gas
    const intrinsic = intrinsicGas(tx);
    if (intrinsic > tx.gas_limit) return TransactionError.IntrinsicGasExceedsLimit;

    // 3. Validate gas limit against block
    if (tx.gas_limit > block.gas_limit) return TransactionError.GasLimitExceedsBlock;

    // 4. Compute effective gas price
    if (tx.tx_type == .dynamic_fee) {
        const max_fee = tx.max_fee_per_gas orelse return TransactionError.MissingGasPrice;
        if (max_fee < block.base_fee) return TransactionError.MaxFeeUnderBaseFee;
    }
    const gas_price = try effectiveGasPrice(tx, block.base_fee);

    // 5. Check sender balance >= value + gas_limit * gas_price
    const gas_cost = types.U256.fromU64(tx.gas_limit).mul(types.U256.fromU64(gas_price));
    const total_cost = tx.value.add(gas_cost);
    const sender_balance = try state_db.getBalance(tx.from);
    if (sender_balance.lt(total_cost)) return TransactionError.InsufficientBalance;

    // 6. Compute coinbase gas price (priority fee for EIP-1559)
    const coinbase_gas_price: u64 = switch (tx.tx_type) {
        .legacy, .access_list => gas_price,
        .dynamic_fee => blk: {
            const priority = tx.max_priority_fee_per_gas orelse 0;
            break :blk @min(priority, gas_price -| block.base_fee);
        },
    };

    // 7. Deduct up-front gas payment from sender
    try state_db.setBalance(tx.from, sender_balance.sub(gas_cost));

    // 8. Increment sender nonce
    try state_db.incrementNonce(tx.from);

    // 9. Take a snapshot so we can revert EVM-internal state on failure
    const snap = try state_db.snapshot();
    var snap_committed = false;
    defer if (!snap_committed) state_db.revertToSnapshot(snap) catch {};

    // 9. Pre-warm accessed addresses/keys (EIP-2930)
    //    (The EVM warm_accounts map is populated below when we build the child.)

    // 10. Execute
    var created_address: ?types.Address = null;
    var evm_result: evm.ExecutionResult = undefined;

    const gas_available = tx.gas_limit - intrinsic;

    if (tx.to) |to_addr| {
        // --- Message call ---
        // Transfer value
        const recipient_balance = try state_db.getBalance(to_addr);
        const sender_bal_after = try state_db.getBalance(tx.from);
        if (!tx.value.isZero()) {
            if (sender_bal_after.lt(tx.value)) {
                // This shouldn't happen after the upfront check, but be safe.
                try state_db.commitSnapshot(snap);
                snap_committed = true;
                return TransactionResult{
                    .success = false,
                    .gas_used = tx.gas_limit,
                    .gas_refund = 0,
                    .return_data = &[_]u8{},
                    .logs = &[_]evm.Log{},
                    .created_address = null,
                };
            }
            try state_db.setBalance(tx.from, sender_bal_after.sub(tx.value));
            try state_db.setBalance(to_addr, recipient_balance.add(tx.value));
        }

        const code = state_db.getCode(to_addr);
        if (code.len == 0) {
            // Simple value transfer — no code to execute.
            try state_db.commitSnapshot(snap);
            snap_committed = true;

            // Refund unused gas to sender
            const unused_gas = gas_available;
            const refund_wei = types.U256.fromU64(unused_gas).mul(types.U256.fromU64(gas_price));
            const sender_bal_final = try state_db.getBalance(tx.from);
            try state_db.setBalance(tx.from, sender_bal_final.add(refund_wei));

            // Pay coinbase
            const cb_payment = types.U256.fromU64(intrinsic).mul(types.U256.fromU64(coinbase_gas_price));
            const cb_balance = try state_db.getBalance(block.coinbase);
            try state_db.setBalance(block.coinbase, cb_balance.add(cb_payment));

            return TransactionResult{
                .success = true,
                .gas_used = intrinsic,
                .gas_refund = 0,
                .return_data = &[_]u8{},
                .logs = &[_]evm.Log{},
                .created_address = null,
            };
        }

        // Execute contract code
        var ctx = evm.ExecutionContext.default();
        ctx.caller = tx.from;
        ctx.origin = tx.from;
        ctx.address = to_addr;
        ctx.value = tx.value;
        ctx.calldata = tx.data;
        ctx.code = code;
        ctx.block_number = block.number;
        ctx.block_timestamp = block.timestamp;
        ctx.block_coinbase = block.coinbase;
        ctx.block_difficulty = block.difficulty;
        ctx.block_gaslimit = block.gas_limit;
        ctx.chain_id = block.chain_id;
        ctx.block_base_fee = block.base_fee;
        ctx.block_prev_randao = block.prev_randao;

        var vm = try evm.EVM.initWithContext(allocator, gas_available, ctx);
        defer vm.deinit();
        vm.state_db = state_db;
        warmAccessList(&vm, tx);

        evm_result = vm.execute(code, tx.data) catch {
            // OOG or other hard error — all gas consumed
            try state_db.commitSnapshot(snap);
            snap_committed = true;

            // Pay coinbase full gas_limit
            const coinbase_payment = types.U256.fromU64(tx.gas_limit).mul(types.U256.fromU64(coinbase_gas_price));
            const coinbase_balance = try state_db.getBalance(block.coinbase);
            try state_db.setBalance(block.coinbase, coinbase_balance.add(coinbase_payment));

            return TransactionResult{
                .success = false,
                .gas_used = tx.gas_limit,
                .gas_refund = 0,
                .return_data = &[_]u8{},
                .logs = &[_]evm.Log{},
                .created_address = null,
            };
        };
    } else {
        // --- Contract creation ---
        const new_address = deriveCreateAddress(tx.from, tx.nonce);
        created_address = new_address;

        // Transfer value to new contract
        try state_db.createAccount(new_address);
        if (!tx.value.isZero()) {
            const sender_bal_after = try state_db.getBalance(tx.from);
            try state_db.setBalance(tx.from, sender_bal_after.sub(tx.value));
            try state_db.setBalance(new_address, tx.value);
        }

        var ctx = evm.ExecutionContext.default();
        ctx.caller = tx.from;
        ctx.origin = tx.from;
        ctx.address = new_address;
        ctx.value = tx.value;
        ctx.calldata = &[_]u8{};
        ctx.code = tx.data;
        ctx.block_number = block.number;
        ctx.block_timestamp = block.timestamp;
        ctx.block_coinbase = block.coinbase;
        ctx.block_difficulty = block.difficulty;
        ctx.block_gaslimit = block.gas_limit;
        ctx.chain_id = block.chain_id;
        ctx.block_base_fee = block.base_fee;
        ctx.block_prev_randao = block.prev_randao;

        var vm = try evm.EVM.initWithContext(allocator, gas_available, ctx);
        defer vm.deinit();
        vm.state_db = state_db;
        warmAccessList(&vm, tx);

        evm_result = vm.execute(tx.data, &[_]u8{}) catch {
            try state_db.commitSnapshot(snap);
            snap_committed = true;

            const cb_err_payment = types.U256.fromU64(tx.gas_limit).mul(types.U256.fromU64(coinbase_gas_price));
            const cb_err_balance = try state_db.getBalance(block.coinbase);
            try state_db.setBalance(block.coinbase, cb_err_balance.add(cb_err_payment));

            return TransactionResult{
                .success = false,
                .gas_used = tx.gas_limit,
                .gas_refund = 0,
                .return_data = &[_]u8{},
                .logs = &[_]evm.Log{},
                .created_address = null,
            };
        };

        // Store returned bytecode as contract code
        if (evm_result.success and evm_result.return_data.len > 0) {
            try state_db.setCode(new_address, evm_result.return_data);
        }
    }

    // 11. Compute gas refund (capped at gas_used / 5 per EIP-3529)
    const evm_gas_used = intrinsic + evm_result.gas_used;
    const max_refund = evm_gas_used / 5;
    const actual_refund = @min(evm_result.gas_refund, max_refund);
    const net_gas_used = evm_gas_used - actual_refund;

    // 12. Commit the EVM state changes
    try state_db.commitSnapshot(snap);
    snap_committed = true;

    // 13. Refund unused gas to sender
    const unused_gas = tx.gas_limit - net_gas_used;
    const refund_wei = types.U256.fromU64(unused_gas).mul(types.U256.fromU64(gas_price));
    const sender_bal_final = try state_db.getBalance(tx.from);
    try state_db.setBalance(tx.from, sender_bal_final.add(refund_wei));

    // 14. Pay coinbase: net_gas_used * effective_gas_price (priority fee for EIP-1559)
    const coinbase_payment = types.U256.fromU64(net_gas_used).mul(types.U256.fromU64(coinbase_gas_price));
    const coinbase_balance = try state_db.getBalance(block.coinbase);
    try state_db.setBalance(block.coinbase, coinbase_balance.add(coinbase_payment));

    return TransactionResult{
        .success = evm_result.success,
        .gas_used = net_gas_used,
        .gas_refund = actual_refund,
        .return_data = evm_result.return_data,
        .logs = evm_result.logs,
        .created_address = created_address,
    };
}

/// Pre-warm EIP-2930 access list entries in the EVM instance.
fn warmAccessList(vm: *evm.EVM, tx: Transaction) void {
    // Always warm the sender and recipient (or contract address).
    vm.warm_accounts.put(tx.from, {}) catch {};
    if (tx.to) |to_addr| {
        vm.warm_accounts.put(to_addr, {}) catch {};
    }

    if (tx.access_list) |al| {
        for (al) |entry| {
            vm.warm_accounts.put(entry.address, {}) catch {};
            for (entry.storage_keys) |key| {
                vm.warm_storage.put(key, {}) catch {};
            }
        }
    }
}

// ===========================================================================
// Tests
// ===========================================================================

fn testBlockContext() BlockContext {
    return BlockContext{
        .number = 15_000_000,
        .timestamp = 1_700_000_000,
        .coinbase = coinbaseAddr(),
        .difficulty = types.U256.fromU64(0),
        .gas_limit = 30_000_000,
        .base_fee = 10, // 10 wei base fee for easy math
        .chain_id = 1,
    };
}

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

test "simple value transfer costs exactly 21000 gas" {
    const allocator = std.testing.allocator;
    var db = state.StateDB.init(allocator);
    defer db.deinit();

    const sender = senderAddr();
    const recipient = recipientAddr();
    const coinbase = coinbaseAddr();

    // Fund sender: 1 ETH (1e18 wei)
    try db.createAccount(sender);
    try db.setBalance(sender, types.U256.fromU64(1_000_000_000_000_000_000));
    try db.createAccount(coinbase);

    const block = testBlockContext();
    const gas_price: u64 = 20;

    const tx = Transaction{
        .tx_type = .legacy,
        .nonce = 0,
        .gas_limit = 21_000,
        .to = recipient,
        .value = types.U256.fromU64(1_000_000),
        .data = &[_]u8{},
        .gas_price = gas_price,
        .from = sender,
    };

    const result = try executeTransaction(allocator, tx, &db, block);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u64, 21_000), result.gas_used);
    try std.testing.expectEqual(@as(u64, 0), result.gas_refund);
    try std.testing.expect(result.created_address == null);

    // Recipient got the value
    const recipient_bal = try db.getBalance(recipient);
    try std.testing.expectEqual(@as(u64, 1_000_000), recipient_bal.limbs[0]);

    // Sender balance = initial - value - gas_used * gas_price
    const sender_bal = try db.getBalance(sender);
    const expected_sender = 1_000_000_000_000_000_000 - 1_000_000 - (21_000 * gas_price);
    try std.testing.expectEqual(expected_sender, sender_bal.limbs[0]);

    // Coinbase got the gas payment (legacy: full gas_price)
    const coinbase_bal = try db.getBalance(coinbase);
    try std.testing.expectEqual(@as(u64, 21_000 * gas_price), coinbase_bal.limbs[0]);
}

test "contract creation with init code" {
    const allocator = std.testing.allocator;
    var db = state.StateDB.init(allocator);
    defer db.deinit();

    const sender = senderAddr();
    const coinbase = coinbaseAddr();

    try db.createAccount(sender);
    try db.setBalance(sender, types.U256.fromU64(1_000_000_000_000_000_000));
    try db.createAccount(coinbase);

    const block = testBlockContext();
    const gas_price: u64 = 20;

    // Init code: PUSH1 0x42 PUSH1 0x00 MSTORE PUSH1 0x01 PUSH1 0x1F RETURN
    // This stores 0x42 in memory and returns 1 byte (the deployed bytecode: 0x42).
    const init_code = [_]u8{
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x00, // PUSH1 0x00
        0x52, // MSTORE
        0x60, 0x01, // PUSH1 0x01
        0x60, 0x1F, // PUSH1 0x1F
        0xF3, // RETURN
    };

    const tx = Transaction{
        .tx_type = .legacy,
        .nonce = 0,
        .gas_limit = 100_000,
        .to = null, // contract creation
        .value = types.U256.zero(),
        .data = &init_code,
        .gas_price = gas_price,
        .from = sender,
    };

    const result = try executeTransaction(allocator, tx, &db, block);
    defer if (result.return_data.len > 0) allocator.free(@constCast(result.return_data));
    defer allocator.free(@constCast(result.logs));

    try std.testing.expect(result.success);
    try std.testing.expect(result.created_address != null);

    // Intrinsic gas for creation = 53000 + calldata cost
    // init_code has 10 nonzero bytes → 53000 + 10*16 = 53160
    const expected_intrinsic: u64 = 53_000 + 10 * 16;
    try std.testing.expect(result.gas_used >= expected_intrinsic);

    // Check deployed code exists at created address
    const created = result.created_address.?;
    const deployed = db.getCode(created);
    try std.testing.expectEqual(@as(usize, 1), deployed.len);
    try std.testing.expectEqual(@as(u8, 0x42), deployed[0]);
}

test "EIP-1559 effective gas price calculation" {
    const allocator = std.testing.allocator;
    var db = state.StateDB.init(allocator);
    defer db.deinit();

    const sender = senderAddr();
    const recipient = recipientAddr();
    const coinbase = coinbaseAddr();

    try db.createAccount(sender);
    try db.setBalance(sender, types.U256.fromU64(1_000_000_000_000_000_000));
    try db.createAccount(coinbase);

    var block = testBlockContext();
    block.base_fee = 10;

    const tx = Transaction{
        .tx_type = .dynamic_fee,
        .nonce = 0,
        .gas_limit = 21_000,
        .to = recipient,
        .value = types.U256.fromU64(0),
        .data = &[_]u8{},
        .max_fee_per_gas = 30,
        .max_priority_fee_per_gas = 5,
        .from = sender,
    };

    const result = try executeTransaction(allocator, tx, &db, block);
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u64, 21_000), result.gas_used);

    // effective_gas_price = min(max_fee=30, base_fee=10 + priority=5) = 15
    // Sender pays: 21000 * 15 = 315000
    // Coinbase gets priority fee: 21000 * min(5, 15-10) = 21000 * 5 = 105000
    const coinbase_bal = try db.getBalance(coinbase);
    try std.testing.expectEqual(@as(u64, 21_000 * 5), coinbase_bal.limbs[0]);

    // Sender: initial - gas_cost
    // Up-front deduction was 21000 * 15 = 315000, all consumed (21000 gas used at price 15).
    const sender_bal = try db.getBalance(sender);
    const expected = 1_000_000_000_000_000_000 - (21_000 * 15);
    try std.testing.expectEqual(expected, sender_bal.limbs[0]);
}

test "nonce mismatch rejection" {
    const allocator = std.testing.allocator;
    var db = state.StateDB.init(allocator);
    defer db.deinit();

    const sender = senderAddr();
    try db.createAccount(sender);
    try db.setBalance(sender, types.U256.fromU64(1_000_000_000_000_000_000));

    const block = testBlockContext();

    const tx = Transaction{
        .tx_type = .legacy,
        .nonce = 5, // Account nonce is 0 — mismatch
        .gas_limit = 21_000,
        .to = recipientAddr(),
        .value = types.U256.fromU64(0),
        .data = &[_]u8{},
        .gas_price = 20,
        .from = sender,
    };

    const err = executeTransaction(allocator, tx, &db, block);
    try std.testing.expectError(TransactionError.NonceMismatch, err);

    // Sender balance unchanged
    const bal = try db.getBalance(sender);
    try std.testing.expectEqual(@as(u64, 1_000_000_000_000_000_000), bal.limbs[0]);
}

test "insufficient balance rejection" {
    const allocator = std.testing.allocator;
    var db = state.StateDB.init(allocator);
    defer db.deinit();

    const sender = senderAddr();
    try db.createAccount(sender);
    // Only 100 wei — cannot afford 21000 * 20 = 420000 gas cost
    try db.setBalance(sender, types.U256.fromU64(100));

    const block = testBlockContext();

    const tx = Transaction{
        .tx_type = .legacy,
        .nonce = 0,
        .gas_limit = 21_000,
        .to = recipientAddr(),
        .value = types.U256.fromU64(0),
        .data = &[_]u8{},
        .gas_price = 20,
        .from = sender,
    };

    const err = executeTransaction(allocator, tx, &db, block);
    try std.testing.expectError(TransactionError.InsufficientBalance, err);

    // Sender balance unchanged
    const bal = try db.getBalance(sender);
    try std.testing.expectEqual(@as(u64, 100), bal.limbs[0]);
}

test "gas refund capped at gas_used / 5 (EIP-3529)" {
    // Verifying the cap arithmetic directly.
    // A transaction that uses 100_000 gas with a 50_000 refund should only
    // receive 20_000 back (100_000 / 5 = 20_000).

    const evm_gas_used: u64 = 100_000;
    const evm_refund: u64 = 50_000;
    const max_refund = evm_gas_used / 5;
    const actual_refund = @min(evm_refund, max_refund);

    try std.testing.expectEqual(@as(u64, 20_000), max_refund);
    try std.testing.expectEqual(@as(u64, 20_000), actual_refund);
    try std.testing.expectEqual(@as(u64, 80_000), evm_gas_used - actual_refund);
}

test "intrinsic gas calculation" {
    // Simple transfer: 21000
    const simple_tx = Transaction{
        .nonce = 0,
        .gas_limit = 21_000,
        .to = recipientAddr(),
        .value = types.U256.zero(),
        .data = &[_]u8{},
        .gas_price = 1,
        .from = senderAddr(),
    };
    try std.testing.expectEqual(@as(u64, 21_000), intrinsicGas(simple_tx));

    // Contract creation: 53000
    const create_tx = Transaction{
        .nonce = 0,
        .gas_limit = 100_000,
        .to = null,
        .value = types.U256.zero(),
        .data = &[_]u8{},
        .gas_price = 1,
        .from = senderAddr(),
    };
    try std.testing.expectEqual(@as(u64, 53_000), intrinsicGas(create_tx));

    // Calldata: 2 zero bytes + 3 non-zero bytes = 21000 + 2*4 + 3*16 = 21056
    const data_tx = Transaction{
        .nonce = 0,
        .gas_limit = 100_000,
        .to = recipientAddr(),
        .value = types.U256.zero(),
        .data = &[_]u8{ 0x00, 0x00, 0xFF, 0xAA, 0x01 },
        .gas_price = 1,
        .from = senderAddr(),
    };
    try std.testing.expectEqual(@as(u64, 21_000 + 2 * 4 + 3 * 16), intrinsicGas(data_tx));

    // Access list: 1 address, 2 storage keys = 21000 + 2400 + 2*1900 = 27200
    const keys = [_]types.U256{ types.U256.fromU64(1), types.U256.fromU64(2) };
    const al_entries = [_]AccessListEntry{.{
        .address = recipientAddr(),
        .storage_keys = &keys,
    }};
    const al_tx = Transaction{
        .tx_type = .access_list,
        .nonce = 0,
        .gas_limit = 100_000,
        .to = recipientAddr(),
        .value = types.U256.zero(),
        .data = &[_]u8{},
        .gas_price = 1,
        .from = senderAddr(),
        .access_list = &al_entries,
    };
    try std.testing.expectEqual(@as(u64, 21_000 + 2_400 + 2 * 1_900), intrinsicGas(al_tx));
}

test "intrinsic gas exceeds limit rejection" {
    const allocator = std.testing.allocator;
    var db = state.StateDB.init(allocator);
    defer db.deinit();

    const sender = senderAddr();
    try db.createAccount(sender);
    try db.setBalance(sender, types.U256.fromU64(1_000_000_000_000_000_000));

    const block = testBlockContext();

    // gas_limit 20_000 < intrinsic 21_000
    const tx = Transaction{
        .tx_type = .legacy,
        .nonce = 0,
        .gas_limit = 20_000,
        .to = recipientAddr(),
        .value = types.U256.fromU64(0),
        .data = &[_]u8{},
        .gas_price = 20,
        .from = sender,
    };

    const err = executeTransaction(allocator, tx, &db, block);
    try std.testing.expectError(TransactionError.IntrinsicGasExceedsLimit, err);
}

test "EIP-1559 max_fee below base_fee rejection" {
    const allocator = std.testing.allocator;
    var db = state.StateDB.init(allocator);
    defer db.deinit();

    const sender = senderAddr();
    try db.createAccount(sender);
    try db.setBalance(sender, types.U256.fromU64(1_000_000_000_000_000_000));

    var block = testBlockContext();
    block.base_fee = 100;

    const tx = Transaction{
        .tx_type = .dynamic_fee,
        .nonce = 0,
        .gas_limit = 21_000,
        .to = recipientAddr(),
        .value = types.U256.fromU64(0),
        .data = &[_]u8{},
        .max_fee_per_gas = 50, // below base_fee of 100
        .max_priority_fee_per_gas = 5,
        .from = sender,
    };

    const err = executeTransaction(allocator, tx, &db, block);
    try std.testing.expectError(TransactionError.MaxFeeUnderBaseFee, err);
}
