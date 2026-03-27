const std = @import("std");
const evm = @import("evm");
const types = @import("types");
const state = @import("state");
const crypto = @import("crypto");

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn addressFromByte(b: u8) types.Address {
    var bytes: [20]u8 = [_]u8{0} ** 20;
    bytes[19] = b;
    return types.Address{ .bytes = bytes };
}

fn addressToU256(address: types.Address) types.U256 {
    var value = types.U256.zero();
    for (0..20) |i| {
        const limb_idx = i / 8;
        const shift: u6 = @intCast((i % 8) * 8);
        value.limbs[limb_idx] |= (@as(u64, address.bytes[19 - i]) << shift);
    }
    return value;
}

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

fn deriveCreate2Address(sender: types.Address, salt: types.U256, init_code: []const u8) types.Address {
    var init_hash: [32]u8 = undefined;
    crypto.keccak256(init_code, &init_hash);

    var preimage: [85]u8 = undefined;
    preimage[0] = 0xff;
    @memcpy(preimage[1..21], sender.bytes[0..20]);
    const salt_bytes = salt.toBytes();
    @memcpy(preimage[21..53], salt_bytes[0..32]);
    @memcpy(preimage[53..85], init_hash[0..32]);

    var hash: [32]u8 = undefined;
    crypto.keccak256(&preimage, &hash);
    var address_bytes: [20]u8 = undefined;
    @memcpy(&address_bytes, hash[12..32]);
    return types.Address{ .bytes = address_bytes };
}

/// Free an ExecutionResult's owned slices.
fn freeResult(allocator: std.mem.Allocator, result: evm.ExecutionResult) void {
    if (result.return_data.len > 0) allocator.free(result.return_data);
    allocator.free(result.logs);
}

/// Encode a 20-byte address into a PUSH20 sequence (0x73 + 20 bytes).
fn push20(addr: types.Address) [21]u8 {
    var out: [21]u8 = undefined;
    out[0] = 0x73; // PUSH20
    @memcpy(out[1..21], addr.bytes[0..20]);
    return out;
}

// ---------------------------------------------------------------------------
// Bytecode builders
// ---------------------------------------------------------------------------

/// Bytecode: SSTORE(key, value) then STOP.
fn childSstoreStop(key: u8, value: u8) [6]u8 {
    return [_]u8{
        0x60, value, // PUSH1 value
        0x60, key, //   PUSH1 key
        0x55, //        SSTORE
        0x00, //        STOP
    };
}

/// Bytecode: SSTORE(key, value) then REVERT(0, 0).
fn childSstoreRevert(key: u8, value: u8) [10]u8 {
    return [_]u8{
        0x60, value, // PUSH1 value
        0x60, key, //   PUSH1 key
        0x55, //        SSTORE
        0x60, 0x00, //  PUSH1 0 (revert size)
        0x60, 0x00, //  PUSH1 0 (revert offset)
        0xfd, //        REVERT
    };
}

/// Build CALL(gas=0xffff, addr, value, inOff=0, inSize=0, outOff=0, outSize=0).
/// Returns the bytecode as a fixed-size array.
fn buildCallBytecode(addr: types.Address, value: u8) [35]u8 {
    var buf: [35]u8 = undefined;
    var i: usize = 0;

    // outSize = 0
    buf[i] = 0x60;
    i += 1;
    buf[i] = 0x00;
    i += 1;
    // outOff = 0
    buf[i] = 0x60;
    i += 1;
    buf[i] = 0x00;
    i += 1;
    // inSize = 0
    buf[i] = 0x60;
    i += 1;
    buf[i] = 0x00;
    i += 1;
    // inOff = 0
    buf[i] = 0x60;
    i += 1;
    buf[i] = 0x00;
    i += 1;
    // value
    buf[i] = 0x60;
    i += 1;
    buf[i] = value;
    i += 1;
    // address (PUSH20)
    const p20 = push20(addr);
    @memcpy(buf[i .. i + 21], &p20);
    i += 21;
    // gas = 0xffff
    buf[i] = 0x61;
    i += 1; // PUSH2
    buf[i] = 0xff;
    i += 1;
    buf[i] = 0xff;
    i += 1;
    // CALL
    buf[i] = 0xf1;
    i += 1;

    return buf;
}

/// Build CALL followed by STOP.
fn buildCallStop(addr: types.Address, value: u8) [36]u8 {
    const call_code = buildCallBytecode(addr, value);
    var buf: [36]u8 = undefined;
    @memcpy(buf[0..35], &call_code);
    buf[35] = 0x00; // STOP
    return buf;
}

/// Build CALL followed by REVERT(0, 0).
fn buildCallRevert(addr: types.Address, value: u8) [40]u8 {
    const call_code = buildCallBytecode(addr, value);
    var buf: [40]u8 = undefined;
    @memcpy(buf[0..35], &call_code);
    buf[35] = 0x60; // PUSH1 0
    buf[36] = 0x00;
    buf[37] = 0x60; // PUSH1 0
    buf[38] = 0x00;
    buf[39] = 0xfd; // REVERT
    return buf;
}

// ---------------------------------------------------------------------------
// Test 1: Nested CALL success commits storage changes
// ---------------------------------------------------------------------------

test "journal: nested CALL success commits storage" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const caller_addr = addressFromByte(0xAA);
    const child_addr = addressFromByte(0xBB);

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    // Set up accounts
    try db.setAccount(caller_addr, .{
        .nonce = 0,
        .balance = types.U256.fromU64(1000),
        .storage_root = types.Hash.zero,
        .code_hash = types.Hash.zero,
    });

    const child_code = childSstoreStop(1, 42);
    try db.createAccount(child_addr);
    try db.setCode(child_addr, &child_code);

    // Caller bytecode: CALL child with value=0, then STOP
    const caller_code = buildCallStop(child_addr, 0);

    var ctx = evm.ExecutionContext.default();
    ctx.caller = caller_addr;
    ctx.origin = caller_addr;
    ctx.address = caller_addr;

    var vm = try evm.EVM.initWithState(allocator, 1_000_000, ctx, &db);
    defer vm.deinit();

    const result = try vm.execute(&caller_code, &[_]u8{});
    defer freeResult(allocator, result);

    try testing.expect(result.success);

    // Child's SSTORE should be committed: storage[child_addr][1] == 42
    const stored = try db.getStorage(child_addr, types.U256.fromU64(1));
    try testing.expectEqual(@as(u64, 42), stored.limbs[0]);
}

// ---------------------------------------------------------------------------
// Test 2: Nested CALL revert rolls back storage changes
// ---------------------------------------------------------------------------

test "journal: nested CALL revert rolls back storage" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const caller_addr = addressFromByte(0xAA);
    const child_addr = addressFromByte(0xBB);

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    try db.setAccount(caller_addr, .{
        .nonce = 0,
        .balance = types.U256.fromU64(1000),
        .storage_root = types.Hash.zero,
        .code_hash = types.Hash.zero,
    });

    const child_code = childSstoreRevert(1, 42);
    try db.createAccount(child_addr);
    try db.setCode(child_addr, &child_code);

    const caller_code = buildCallStop(child_addr, 0);

    var ctx = evm.ExecutionContext.default();
    ctx.caller = caller_addr;
    ctx.origin = caller_addr;
    ctx.address = caller_addr;

    var vm = try evm.EVM.initWithState(allocator, 1_000_000, ctx, &db);
    defer vm.deinit();

    const result = try vm.execute(&caller_code, &[_]u8{});
    defer freeResult(allocator, result);

    // Caller succeeds (CALL returns 0 on stack but execution continues to STOP)
    try testing.expect(result.success);

    // Child reverted, so storage[child_addr][1] should be 0
    const stored = try db.getStorage(child_addr, types.U256.fromU64(1));
    try testing.expectEqual(@as(u64, 0), stored.limbs[0]);
}

// ---------------------------------------------------------------------------
// Test 3: Nested CALL revert rolls back balance transfer
// ---------------------------------------------------------------------------

test "journal: nested CALL revert rolls back balance transfer" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const caller_addr = addressFromByte(0xAA);
    const child_addr = addressFromByte(0xBB);

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    try db.setAccount(caller_addr, .{
        .nonce = 0,
        .balance = types.U256.fromU64(100),
        .storage_root = types.Hash.zero,
        .code_hash = types.Hash.zero,
    });

    // Child code: just REVERT immediately
    const child_code = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0xfd };
    try db.createAccount(child_addr);
    try db.setCode(child_addr, &child_code);

    // Caller calls child with value=50
    const caller_code = buildCallStop(child_addr, 50);

    var ctx = evm.ExecutionContext.default();
    ctx.caller = caller_addr;
    ctx.origin = caller_addr;
    ctx.address = caller_addr;

    var vm = try evm.EVM.initWithState(allocator, 1_000_000, ctx, &db);
    defer vm.deinit();

    const result = try vm.execute(&caller_code, &[_]u8{});
    defer freeResult(allocator, result);

    try testing.expect(result.success);

    // Balance should be restored: caller=100, child=0
    const caller_bal = try db.getBalance(caller_addr);
    try testing.expectEqual(@as(u64, 100), caller_bal.limbs[0]);

    const child_bal = try db.getBalance(child_addr);
    try testing.expectEqual(@as(u64, 0), child_bal.limbs[0]);
}

// ---------------------------------------------------------------------------
// Test 4: Double-nested CALL: inner revert, outer success
// ---------------------------------------------------------------------------

test "journal: double-nested CALL inner revert outer success" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const addr_a = addressFromByte(0xA0);
    const addr_b = addressFromByte(0xB0);
    const addr_c = addressFromByte(0xC0);

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    // Set up A with plenty of balance
    try db.setAccount(addr_a, .{
        .nonce = 0,
        .balance = types.U256.fromU64(10000),
        .storage_root = types.Hash.zero,
        .code_hash = types.Hash.zero,
    });

    // C: SSTORE(1, 99) then REVERT -- C's changes should be rolled back
    const c_code = childSstoreRevert(1, 99);
    try db.createAccount(addr_c);
    try db.setCode(addr_c, &c_code);

    // B: CALL C (value=0), then SSTORE(1, 77), then STOP
    // B's own storage write should persist since B succeeds
    const call_c = buildCallBytecode(addr_c, 0);
    const b_code = call_c ++ [_]u8{
        0x50, //        POP (discard CALL result)
        0x60, 77, //    PUSH1 77
        0x60, 1, //     PUSH1 1
        0x55, //        SSTORE
        0x00, //        STOP
    };
    try db.createAccount(addr_b);
    try db.setCode(addr_b, &b_code);

    // A: CALL B (value=0), STOP
    const a_code = buildCallStop(addr_b, 0);

    var ctx = evm.ExecutionContext.default();
    ctx.caller = addr_a;
    ctx.origin = addr_a;
    ctx.address = addr_a;

    var vm = try evm.EVM.initWithState(allocator, 5_000_000, ctx, &db);
    defer vm.deinit();

    const result = try vm.execute(&a_code, &[_]u8{});
    defer freeResult(allocator, result);

    try testing.expect(result.success);

    // C reverted: storage[C][1] == 0
    const c_stored = try db.getStorage(addr_c, types.U256.fromU64(1));
    try testing.expectEqual(@as(u64, 0), c_stored.limbs[0]);

    // B succeeded: storage[B][1] == 77
    const b_stored = try db.getStorage(addr_b, types.U256.fromU64(1));
    try testing.expectEqual(@as(u64, 77), b_stored.limbs[0]);
}

// ---------------------------------------------------------------------------
// Bytecode helper: write N bytes to memory via MSTORE8, starting at offset 0.
// Returns a buffer with the bytecode and its length.
// Each byte costs 3 instructions: PUSH1 <byte>, PUSH1 <offset>, MSTORE8 (0x53)
// ---------------------------------------------------------------------------

fn buildMstore8Sequence(comptime data: []const u8) [data.len * 5]u8 {
    var buf: [data.len * 5]u8 = undefined;
    for (data, 0..) |b, i| {
        buf[i * 5 + 0] = 0x60; // PUSH1
        buf[i * 5 + 1] = b; //    byte value
        buf[i * 5 + 2] = 0x60; // PUSH1
        buf[i * 5 + 3] = @intCast(i); // offset
        buf[i * 5 + 4] = 0x53; // MSTORE8
    }
    return buf;
}

// ---------------------------------------------------------------------------
// Test 5: CREATE success - new account persists with code and balance
// ---------------------------------------------------------------------------

test "journal: CREATE success persists code and balance" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const creator_addr = addressFromByte(0xAA);

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    try db.setAccount(creator_addr, .{
        .nonce = 0,
        .balance = types.U256.fromU64(1000),
        .storage_root = types.Hash.zero,
        .code_hash = types.Hash.zero,
    });

    // Init code that deploys runtime [0x60, 0x42]:
    // MSTORE8(0, 0x60); MSTORE8(1, 0x42); RETURN(0, 2)
    const init_code = [_]u8{
        0x60, 0x60, 0x60, 0x00, 0x53, // MSTORE8(0, 0x60)
        0x60, 0x42, 0x60, 0x01, 0x53, // MSTORE8(1, 0x42)
        0x60, 0x02, //                    PUSH1 2 (size)
        0x60, 0x00, //                    PUSH1 0 (offset)
        0xf3, //                           RETURN
    };

    // Creator bytecode: store init_code in memory via MSTORE8, then CREATE
    const mem_code = comptime buildMstore8Sequence(&init_code);
    const creator_code = mem_code ++ [_]u8{
        0x60, @intCast(init_code.len), // PUSH1 length
        0x60, 0x00, //                    PUSH1 offset
        0x60, 0x0a, //                    PUSH1 10 (value)
        0xf0, //                           CREATE
        0x50, //                           POP
        0x00, //                           STOP
    };

    const new_address = deriveCreateAddress(creator_addr, 0);

    var ctx = evm.ExecutionContext.default();
    ctx.caller = creator_addr;
    ctx.origin = creator_addr;
    ctx.address = creator_addr;

    var vm = try evm.EVM.initWithState(allocator, 5_000_000, ctx, &db);
    defer vm.deinit();

    const result = try vm.execute(&creator_code, &[_]u8{});
    defer freeResult(allocator, result);

    try testing.expect(result.success);

    // New account should exist with code [0x60, 0x42] and balance 10
    try testing.expect(db.exists(new_address));
    const code = db.getCode(new_address);
    try testing.expectEqual(@as(usize, 2), code.len);
    try testing.expectEqual(@as(u8, 0x60), code[0]);
    try testing.expectEqual(@as(u8, 0x42), code[1]);

    const new_bal = try db.getBalance(new_address);
    try testing.expectEqual(@as(u64, 10), new_bal.limbs[0]);

    // Creator nonce should have incremented
    const creator_nonce = try db.getNonce(creator_addr);
    try testing.expectEqual(@as(u64, 1), creator_nonce);
}

// ---------------------------------------------------------------------------
// Test 6: CREATE failure (revert in init) restores creator state
// ---------------------------------------------------------------------------

test "journal: CREATE failure reverts child state" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const creator_addr = addressFromByte(0xAA);

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    try db.setAccount(creator_addr, .{
        .nonce = 0,
        .balance = types.U256.fromU64(1000),
        .storage_root = types.Hash.zero,
        .code_hash = types.Hash.zero,
    });

    // Init code that immediately reverts: PUSH1 0, PUSH1 0, REVERT
    const init_revert = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0xfd };

    // Store init_revert in memory via MSTORE8, then CREATE(value=10)
    const mem_code = comptime buildMstore8Sequence(&init_revert);
    const creator_code = mem_code ++ [_]u8{
        0x60, @intCast(init_revert.len), // PUSH1 length
        0x60, 0x00, //                      PUSH1 offset
        0x60, 0x0a, //                      PUSH1 10 (value)
        0xf0, //                             CREATE
        0x50, //                             POP
        0x00, //                             STOP
    };

    const new_address = deriveCreateAddress(creator_addr, 0);

    var ctx = evm.ExecutionContext.default();
    ctx.caller = creator_addr;
    ctx.origin = creator_addr;
    ctx.address = creator_addr;

    var vm = try evm.EVM.initWithState(allocator, 5_000_000, ctx, &db);
    defer vm.deinit();

    const result = try vm.execute(&creator_code, &[_]u8{});
    defer freeResult(allocator, result);

    try testing.expect(result.success);

    // CREATE failed: new account should not have code
    const code = db.getCode(new_address);
    try testing.expectEqual(@as(usize, 0), code.len);

    // Creator balance should be restored (value transfer reverted by snapshot)
    const creator_bal = try db.getBalance(creator_addr);
    try testing.expectEqual(@as(u64, 1000), creator_bal.limbs[0]);

    // Nonce increment is inside the CREATE snapshot scope, so on failure the
    // snapshot revert should restore the nonce to 0.
    const creator_nonce = try db.getNonce(creator_addr);
    try testing.expectEqual(@as(u64, 0), creator_nonce);
}

// ---------------------------------------------------------------------------
// Test 7: SELFDESTRUCT in nested call commits on success
// ---------------------------------------------------------------------------

test "journal: SELFDESTRUCT in nested call commits on success" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const caller_addr = addressFromByte(0xAA);
    const child_addr = addressFromByte(0xBB);
    const beneficiary_addr = addressFromByte(0xCC);

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    try db.setAccount(caller_addr, .{
        .nonce = 0,
        .balance = types.U256.fromU64(1000),
        .storage_root = types.Hash.zero,
        .code_hash = types.Hash.zero,
    });

    try db.setAccount(child_addr, .{
        .nonce = 0,
        .balance = types.U256.fromU64(500),
        .storage_root = types.Hash.zero,
        .code_hash = types.Hash.zero,
    });

    // Child code: SELFDESTRUCT to beneficiary
    const p20_beneficiary = push20(beneficiary_addr);
    const child_code = p20_beneficiary ++ [_]u8{0xff}; // PUSH20 beneficiary, SELFDESTRUCT
    try db.setCode(child_addr, &child_code);

    const caller_code = buildCallStop(child_addr, 0);

    var ctx = evm.ExecutionContext.default();
    ctx.caller = caller_addr;
    ctx.origin = caller_addr;
    ctx.address = caller_addr;

    var vm = try evm.EVM.initWithState(allocator, 5_000_000, ctx, &db);
    defer vm.deinit();

    const result = try vm.execute(&caller_code, &[_]u8{});
    defer freeResult(allocator, result);

    try testing.expect(result.success);

    // Child account should be destroyed
    try testing.expect(!db.exists(child_addr));

    // Beneficiary should have received child's balance (500)
    const ben_bal = try db.getBalance(beneficiary_addr);
    try testing.expectEqual(@as(u64, 500), ben_bal.limbs[0]);
}

// ---------------------------------------------------------------------------
// Test 8: SELFDESTRUCT in nested call reverts on parent REVERT
// ---------------------------------------------------------------------------

test "journal: SELFDESTRUCT reverts when ancestor REVERTs" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const caller_addr = addressFromByte(0xAA);
    const addr_a = addressFromByte(0xA1);
    const addr_b = addressFromByte(0xB1);
    const beneficiary_addr = addressFromByte(0xCC);

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    try db.setAccount(caller_addr, .{
        .nonce = 0,
        .balance = types.U256.fromU64(10000),
        .storage_root = types.Hash.zero,
        .code_hash = types.Hash.zero,
    });

    try db.setAccount(addr_a, .{
        .nonce = 0,
        .balance = types.U256.fromU64(0),
        .storage_root = types.Hash.zero,
        .code_hash = types.Hash.zero,
    });

    try db.setAccount(addr_b, .{
        .nonce = 0,
        .balance = types.U256.fromU64(200),
        .storage_root = types.Hash.zero,
        .code_hash = types.Hash.zero,
    });

    // B: SELFDESTRUCT to beneficiary
    const p20_ben = push20(beneficiary_addr);
    const b_code = p20_ben ++ [_]u8{0xff};
    try db.setCode(addr_b, &b_code);

    // A: CALL B (value=0), then STOP  -- A succeeds
    const a_code = buildCallStop(addr_b, 0);
    try db.setCode(addr_a, &a_code);

    // Caller: CALL A (value=0), then REVERT
    const caller_code = buildCallRevert(addr_a, 0);

    var ctx = evm.ExecutionContext.default();
    ctx.caller = caller_addr;
    ctx.origin = caller_addr;
    ctx.address = caller_addr;

    var vm = try evm.EVM.initWithState(allocator, 5_000_000, ctx, &db);
    defer vm.deinit();

    const result = try vm.execute(&caller_code, &[_]u8{});
    defer freeResult(allocator, result);

    // Caller reverted, so the entire top-level transaction reverts
    try testing.expect(!result.success);

    // B should still exist with original balance since top-level reverted
    try testing.expect(db.exists(addr_b));
    const b_bal = try db.getBalance(addr_b);
    try testing.expectEqual(@as(u64, 200), b_bal.limbs[0]);

    // Beneficiary should not have received anything
    const ben_bal = try db.getBalance(beneficiary_addr);
    try testing.expectEqual(@as(u64, 0), ben_bal.limbs[0]);
}

// ---------------------------------------------------------------------------
// Test 9: CREATE2 + SELFDESTRUCT + re-CREATE2 at same address
// ---------------------------------------------------------------------------

test "journal: CREATE2 selfdestruct then re-CREATE2 same address" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const creator_addr = addressFromByte(0xAA);
    const beneficiary_addr = addressFromByte(0xCC);

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    try db.setAccount(creator_addr, .{
        .nonce = 0,
        .balance = types.U256.fromU64(10000),
        .storage_root = types.Hash.zero,
        .code_hash = types.Hash.zero,
    });

    // We'll use a simple init code: MSTORE8(0,0x00) + RETURN(0,1) -> deploys 1-byte STOP runtime.
    // Then we call the deployed contract. After the first CREATE2, we selfdestruct it via
    // a separate call, then CREATE2 again at the same address.
    //
    // However, the deployed runtime needs to include SELFDESTRUCT. So the runtime code is:
    // PUSH20 <beneficiary> SELFDESTRUCT (22 bytes)
    //
    // Build init code: MSTORE8 each byte of runtime + RETURN(0, 22)
    // Since the beneficiary address contains a runtime value, we build the bytecode dynamically.

    const p20_ben = push20(beneficiary_addr);
    const runtime_code: [22]u8 = p20_ben ++ [_]u8{0xff};

    // Init code: MSTORE8 each runtime byte, then RETURN(0, 22)
    var init_code_buf: [22 * 5 + 5]u8 = undefined; // 22*5 for MSTORE8s + 5 for RETURN prefix
    for (runtime_code, 0..) |b, i| {
        init_code_buf[i * 5 + 0] = 0x60; // PUSH1
        init_code_buf[i * 5 + 1] = b;
        init_code_buf[i * 5 + 2] = 0x60; // PUSH1
        init_code_buf[i * 5 + 3] = @intCast(i);
        init_code_buf[i * 5 + 4] = 0x53; // MSTORE8
    }
    const mstore_end = 22 * 5;
    init_code_buf[mstore_end + 0] = 0x60; // PUSH1 22 (size)
    init_code_buf[mstore_end + 1] = 22;
    init_code_buf[mstore_end + 2] = 0x60; // PUSH1 0 (offset)
    init_code_buf[mstore_end + 3] = 0x00;
    init_code_buf[mstore_end + 4] = 0xf3; // RETURN
    const init_code = init_code_buf;
    const init_code_len: u8 = @intCast(init_code.len);

    const salt = types.U256.fromU64(42);
    const actual_addr = deriveCreate2Address(creator_addr, salt, &init_code);

    // Build the creator code dynamically:
    // Phase 1: store init_code in memory via MSTORE8, then CREATE2(value=10, salt=42)
    // Phase 2: POP + CALL created contract (triggers selfdestruct) + POP
    // Phase 3: re-store init_code + CREATE2 again + POP + STOP
    var code_buf: [2048]u8 = undefined;
    var ci: usize = 0;

    // Helper: emit MSTORE8 sequence for init_code
    const emit_init_mstore = struct {
        fn f(buf: []u8, start: usize, ic: []const u8) usize {
            var p = start;
            for (ic, 0..) |b, i| {
                buf[p] = 0x60;
                p += 1;
                buf[p] = b;
                p += 1;
                buf[p] = 0x60;
                p += 1;
                buf[p] = @intCast(i);
                p += 1;
                buf[p] = 0x53;
                p += 1;
            }
            return p;
        }
    }.f;

    // Phase 1: store init code in memory + CREATE2
    ci = emit_init_mstore(&code_buf, ci, &init_code);
    code_buf[ci] = 0x60;
    ci += 1;
    code_buf[ci] = 0x2a;
    ci += 1; // salt=42
    code_buf[ci] = 0x60;
    ci += 1;
    code_buf[ci] = init_code_len;
    ci += 1; // length
    code_buf[ci] = 0x60;
    ci += 1;
    code_buf[ci] = 0x00;
    ci += 1; // offset
    code_buf[ci] = 0x60;
    ci += 1;
    code_buf[ci] = 0x0a;
    ci += 1; // value=10
    code_buf[ci] = 0xf5;
    ci += 1; // CREATE2
    code_buf[ci] = 0x50;
    ci += 1; // POP

    // Phase 2: CALL the deployed contract (triggers SELFDESTRUCT)
    const call_code = buildCallBytecode(actual_addr, 0);
    @memcpy(code_buf[ci .. ci + 35], &call_code);
    ci += 35;
    code_buf[ci] = 0x50;
    ci += 1; // POP

    // Phase 3: re-store init code + CREATE2 again
    ci = emit_init_mstore(&code_buf, ci, &init_code);
    code_buf[ci] = 0x60;
    ci += 1;
    code_buf[ci] = 0x2a;
    ci += 1; // salt=42
    code_buf[ci] = 0x60;
    ci += 1;
    code_buf[ci] = init_code_len;
    ci += 1; // length
    code_buf[ci] = 0x60;
    ci += 1;
    code_buf[ci] = 0x00;
    ci += 1; // offset
    code_buf[ci] = 0x60;
    ci += 1;
    code_buf[ci] = 0x0a;
    ci += 1; // value=10
    code_buf[ci] = 0xf5;
    ci += 1; // CREATE2
    code_buf[ci] = 0x50;
    ci += 1; // POP
    code_buf[ci] = 0x00;
    ci += 1; // STOP

    var ctx = evm.ExecutionContext.default();
    ctx.caller = creator_addr;
    ctx.origin = creator_addr;
    ctx.address = creator_addr;

    var vm = try evm.EVM.initWithState(allocator, 10_000_000, ctx, &db);
    defer vm.deinit();

    const result = try vm.execute(code_buf[0..ci], &[_]u8{});
    defer freeResult(allocator, result);

    try testing.expect(result.success);

    // The address should exist again after re-CREATE2
    try testing.expect(db.exists(actual_addr));

    // Beneficiary should have received 10 from the first selfdestruct
    const ben_bal = try db.getBalance(beneficiary_addr);
    try testing.expect(!ben_bal.isZero());

    // The re-created contract should have balance 10 (from second CREATE2)
    const recreated_bal = try db.getBalance(actual_addr);
    try testing.expectEqual(@as(u64, 10), recreated_bal.limbs[0]);
}

// ---------------------------------------------------------------------------
// Test 10: Nested nonce tracking
// ---------------------------------------------------------------------------

test "journal: nested nonce tracking across CREATE success and failure" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const creator_addr = addressFromByte(0xAA);

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    try db.setAccount(creator_addr, .{
        .nonce = 5, // Start at nonce 5
        .balance = types.U256.fromU64(10000),
        .storage_root = types.Hash.zero,
        .code_hash = types.Hash.zero,
    });

    // Init code that succeeds: MSTORE8(0, 0x00); RETURN(0, 1) -- deploys 1-byte STOP runtime
    const good_init = [_]u8{
        0x60, 0x00, 0x60, 0x00, 0x53, // MSTORE8(0, 0x00)
        0x60, 0x01, //                    PUSH1 1 (size)
        0x60, 0x00, //                    PUSH1 0 (offset)
        0xf3, //                           RETURN
    };

    // Init code that reverts
    const bad_init = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0xfd };

    // Creator code: two CREATEs in sequence.
    // First: good_init (succeeds), Second: bad_init (reverts)
    const good_mem = comptime buildMstore8Sequence(&good_init);
    const bad_mem = comptime buildMstore8Sequence(&bad_init);

    const creator_code = good_mem ++ [_]u8{
        0x60, @intCast(good_init.len), // PUSH1 length
        0x60, 0x00, //                    PUSH1 offset
        0x60, 0x00, //                    PUSH1 value=0
        0xf0, //                           CREATE
        0x50, //                           POP
    } ++ bad_mem ++ [_]u8{
        0x60, @intCast(bad_init.len), // PUSH1 length
        0x60, 0x00, //                   PUSH1 offset
        0x60, 0x00, //                   PUSH1 value=0
        0xf0, //                          CREATE
        0x50, //                          POP
        0x00, //                          STOP
    };

    var ctx = evm.ExecutionContext.default();
    ctx.caller = creator_addr;
    ctx.origin = creator_addr;
    ctx.address = creator_addr;

    var vm = try evm.EVM.initWithState(allocator, 10_000_000, ctx, &db);
    defer vm.deinit();

    const result = try vm.execute(&creator_code, &[_]u8{});
    defer freeResult(allocator, result);

    try testing.expect(result.success);

    // First CREATE succeeds: nonce goes 5 -> 6 (committed).
    // Second CREATE: snapshot taken at nonce=6, nonce incremented to 7 inside snapshot,
    // child reverts, snapshot reverted -> nonce back to 6.
    const final_nonce = try db.getNonce(creator_addr);
    try testing.expectEqual(@as(u64, 6), final_nonce);

    // First created contract should exist (created at nonce=5)
    const first_addr = deriveCreateAddress(creator_addr, 5);
    try testing.expect(db.exists(first_addr));
}
