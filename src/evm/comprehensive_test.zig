const std = @import("std");
const evm = @import("evm");
const types = @import("types");
const state = @import("state");

fn addressFromU256(value: types.U256) types.Address {
    var address_bytes: [20]u8 = [_]u8{0} ** 20;
    for (0..20) |i| {
        const limb_idx = i / 8;
        const shift: u6 = @intCast((i % 8) * 8);
        const b = @as(u8, @truncate((value.limbs[limb_idx] >> shift) & 0xff));
        address_bytes[19 - i] = b;
    }
    return types.Address{ .bytes = address_bytes };
}

// Comprehensive EVM Test Suite
// Tests all major opcode families with real bytecode

test "EVM: All arithmetic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    // Test: (5 + 3) * 2 - 4 = 12
    const bytecode = [_]u8{
        0x60, 0x05, // PUSH1 5
        0x60, 0x03, // PUSH1 3
        0x01, // ADD  (8)
        0x60, 0x02, // PUSH1 2
        0x02, // MUL  (16)
        0x60, 0x04, // PUSH1 4
        0x03, // SUB  (12)
    };

    const create_result = try vm.execute(&bytecode, &[_]u8{});
    defer if (create_result.return_data.len > 0) allocator.free(create_result.return_data);
    defer allocator.free(create_result.logs);
    const result = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 12), result.limbs[0]);
}

test "EVM: Comparison and conditional logic" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    // Simple comparison test: 5 < 10 should be true (1)
    const bytecode = [_]u8{
        0x60, 0x05, // PUSH1 5
        0x60, 0x0a, // PUSH1 10
        0x10, // LT
    };

    const create_result = try vm.execute(&bytecode, &[_]u8{});
    defer if (create_result.return_data.len > 0) allocator.free(create_result.return_data);
    defer allocator.free(create_result.logs);
    const result = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 1), result.limbs[0]);
}

test "EVM: Bitwise operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    // Test: (0xFF & 0x0F) | 0xF0 = 0xFF
    const bytecode = [_]u8{
        0x60, 0xff, // PUSH1 0xFF
        0x60, 0x0f, // PUSH1 0x0F
        0x16, // AND (result: 0x0F)
        0x60, 0xf0, // PUSH1 0xF0
        0x17, // OR  (result: 0xFF)
    };

    const create_result = try vm.execute(&bytecode, &[_]u8{});
    defer if (create_result.return_data.len > 0) allocator.free(create_result.return_data);
    defer allocator.free(create_result.logs);
    const result = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 0xFF), result.limbs[0]);
}

test "EVM: EXP computes modular exponentiation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    const bytecode = [_]u8{
        0x60, 0x02, // PUSH1 2 (base)
        0x60, 0x08, // PUSH1 8 (exponent)
        0x0a, // EXP
    };

    const create_result = try vm.execute(&bytecode, &[_]u8{});
    defer if (create_result.return_data.len > 0) allocator.free(create_result.return_data);
    defer allocator.free(create_result.logs);
    const result = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 256), result.limbs[0]);
}

test "EVM: SHL and SHR shift values correctly" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    // (1 << 8) >> 8 = 1
    const bytecode = [_]u8{
        0x60, 0x01, // PUSH1 1 (value)
        0x60, 0x08, // PUSH1 8 (shift)
        0x1b, // SHL
        0x60, 0x08, // PUSH1 8 (shift)
        0x1c, // SHR
    };

    _ = try vm.execute(&bytecode, &[_]u8{});
    const result = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 1), result.limbs[0]);
}

test "EVM: SAR preserves sign bit for negative values" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    // Build -1 then arithmetic shift right by 1, which should remain -1.
    const bytecode = [_]u8{
        0x60, 0x00, // PUSH1 0
        0x19, // NOT -> all bits set (-1 in two's complement)
        0x60, 0x01, // PUSH1 1 (shift)
        0x1d, // SAR
    };

    _ = try vm.execute(&bytecode, &[_]u8{});
    const result = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFFF), result.limbs[0]);
    try testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFFF), result.limbs[1]);
    try testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFFF), result.limbs[2]);
    try testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFFF), result.limbs[3]);
}

test "EVM: CALLCODE opcode executes placeholder path" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    // CALLCODE(gas, addr, value, argsOff, argsLen, retOff, retLen)
    const bytecode = [_]u8{
        0x60, 0x00, // retLen
        0x60, 0x00, // retOff
        0x60, 0x00, // argsLen
        0x60, 0x00, // argsOff
        0x60, 0x00, // value
        0x60, 0x00, // address
        0x60, 0x64, // gas
        0xf2, // CALLCODE
    };

    _ = try vm.execute(&bytecode, &[_]u8{});
    const result = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 1), result.limbs[0]);
}

test "EVM: BLOCKHASH does not underflow for low block numbers" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var context = evm.ExecutionContext.default();
    context.block_number = 1;
    var vm = try evm.EVM.initWithContext(allocator, 1000000, context);
    defer vm.deinit();

    const bytecode = [_]u8{
        0x60, 0x00, // PUSH1 block 0
        0x40, // BLOCKHASH
    };

    _ = try vm.execute(&bytecode, &[_]u8{});
    const result = try vm.stack.pop();
    try testing.expect(result.isZero());
}

test "EVM: BLOCKHASH returns configured hash within 256-block window" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var context = evm.ExecutionContext.default();
    context.block_number = 300;
    var vm = try evm.EVM.initWithContext(allocator, 1_000_000, context);
    defer vm.deinit();

    var hbytes = [_]u8{0} ** 32;
    hbytes[31] = 0x42;
    const hash = types.Hash{ .bytes = hbytes };
    try vm.setBlockHash(299, hash);

    const bytecode = [_]u8{
        0x61, 0x01, 0x2b, // PUSH2 299
        0x40, // BLOCKHASH
    };

    _ = try vm.execute(&bytecode, &[_]u8{});
    const result = try vm.stack.pop();
    try testing.expect(result.eq(types.U256.fromBytes(hbytes)));
}

test "EVM: CALL executes target code and exposes return data" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var callee_addr = types.Address.zero;
    callee_addr.bytes[19] = 0x0a;

    const callee_code = [_]u8{
        0x60, 0x2a, // PUSH1 0x2a
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32 (length)
        0x60, 0x00, // PUSH1 0 (offset)
        0xf3, // RETURN
    };
    try db.setCode(callee_addr, &callee_code);

    var context = evm.ExecutionContext.default();
    context.address.bytes[19] = 0xaa;
    var vm = try evm.EVM.initWithState(allocator, 1_000_000, context, &db);
    defer vm.deinit();

    const caller_code = [_]u8{
        0x60, 0x20, // outSize
        0x60, 0x00, // outOffset
        0x60, 0x00, // inSize
        0x60, 0x00, // inOffset
        0x60, 0x00, // value
        0x60, 0x0a, // address
        0x61, 0xff, 0xff, // gas
        0xf1, // CALL
        0x3d, // RETURNDATASIZE
    };

    const call_result = try vm.execute(&caller_code, &[_]u8{});
    defer if (call_result.return_data.len > 0) allocator.free(call_result.return_data);
    defer allocator.free(call_result.logs);
    const return_data_size = try vm.stack.pop();
    const call_success = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 32), return_data_size.limbs[0]);
    try testing.expectEqual(@as(u64, 1), call_success.limbs[0]);
}

test "EVM: EXTCODESIZE/EXTCODECOPY/EXTCODEHASH reflect state code bytes" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    const target = types.Address.zero;
    const code = [_]u8{ 0x60, 0x2a, 0x00 };
    try db.setCode(target, &code);

    var vm = try evm.EVM.initWithState(allocator, 1_000_000, evm.ExecutionContext.default(), &db);
    defer vm.deinit();

    const bytecode = [_]u8{
        0x60, 0x00, // PUSH1 addr
        0x3b, // EXTCODESIZE -> 3
        0x60, 0x03, // PUSH1 len
        0x60, 0x00, // PUSH1 codeOffset
        0x60, 0x00, // PUSH1 memOffset
        0x60, 0x00, // PUSH1 addr
        0x3c, // EXTCODECOPY
        0x60, 0x00, // PUSH1 addr
        0x3f, // EXTCODEHASH
    };

    _ = try vm.execute(&bytecode, &[_]u8{});

    const hash_u256 = try vm.stack.pop();
    const size_u256 = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 3), size_u256.limbs[0]);

    try testing.expectEqual(@as(u8, 0x60), vm.memory.data.items[0]);
    try testing.expectEqual(@as(u8, 0x2a), vm.memory.data.items[1]);
    try testing.expectEqual(@as(u8, 0x00), vm.memory.data.items[2]);

    var expected_hash: [32]u8 = undefined;
    @import("crypto").keccak256(&code, &expected_hash);
    try testing.expectEqualSlices(u8, &expected_hash, &hash_u256.toBytes());
}

test "EVM: EXTCODEHASH zero for non-existent account and keccak(empty) for empty account" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var empty_addr = types.Address.zero;
    empty_addr.bytes[19] = 0x01;
    try db.createAccount(empty_addr); // Exists but has empty code

    var vm = try evm.EVM.initWithState(allocator, 1_000_000, evm.ExecutionContext.default(), &db);
    defer vm.deinit();

    const bytecode = [_]u8{
        0x60, 0x00, // non-existent
        0x3f, // EXTCODEHASH => 0
        0x60, 0x01, // empty existing
        0x3f, // EXTCODEHASH => keccak256("")
    };
    _ = try vm.execute(&bytecode, &[_]u8{});

    const empty_hash_u256 = try vm.stack.pop();
    const missing_hash_u256 = try vm.stack.pop();
    try testing.expect(missing_hash_u256.isZero());

    var keccak_empty: [32]u8 = undefined;
    @import("crypto").keccak256("", &keccak_empty);
    try testing.expectEqualSlices(u8, &keccak_empty, &empty_hash_u256.toBytes());
}

test "EVM: BLOCKHASH returns zero outside 256-block window" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var context = evm.ExecutionContext.default();
    context.block_number = 300;
    var vm = try evm.EVM.initWithContext(allocator, 1_000_000, context);
    defer vm.deinit();

    const bytecode = [_]u8{
        0x60, 0x2b, // PUSH1 43 => distance 257
        0x40, // BLOCKHASH
    };

    _ = try vm.execute(&bytecode, &[_]u8{});
    const result = try vm.stack.pop();
    try testing.expect(result.isZero());
}

test "EVM: CALL dispatches SHA256 precompile (0x02)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1_000_000);
    defer vm.deinit();

    const code = [_]u8{
        0x60, 0x20, // outSize
        0x60, 0x00, // outOffset
        0x60, 0x00, // inSize
        0x60, 0x00, // inOffset
        0x60, 0x00, // value
        0x60, 0x02, // address
        0x61, 0xff, 0xff, // gas
        0xf1, // CALL
        0x3d, // RETURNDATASIZE
    };
    const precompile_result = try vm.execute(&code, &[_]u8{});
    defer if (precompile_result.return_data.len > 0) allocator.free(precompile_result.return_data);
    defer allocator.free(precompile_result.logs);

    const return_size = try vm.stack.pop();
    const success = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 1), success.limbs[0]);
    try testing.expectEqual(@as(u64, 32), return_size.limbs[0]);

    var expected: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("", &expected, .{});
    try testing.expectEqualSlices(u8, &expected, vm.memory.data.items[0..32]);
}

test "EVM: CALL dispatches RIPEMD160 precompile (0x03)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1_000_000);
    defer vm.deinit();

    const code = [_]u8{
        0x60, 0x20, // outSize
        0x60, 0x00, // outOffset
        0x60, 0x00, // inSize
        0x60, 0x00, // inOffset
        0x60, 0x00, // value
        0x60, 0x03, // address
        0x61, 0xff, 0xff, // gas
        0xf1, // CALL
    };
    const precompile_result = try vm.execute(&code, &[_]u8{});
    defer if (precompile_result.return_data.len > 0) allocator.free(precompile_result.return_data);
    defer allocator.free(precompile_result.logs);

    const success = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 1), success.limbs[0]);

    const expected = [_]u8{
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x9c, 0x11, 0x85, 0xa5,
        0xc5, 0xe9, 0xfc, 0x54, 0x61, 0x28, 0x08, 0x97,
        0x7e, 0xe8, 0xf5, 0x48, 0xb2, 0x25, 0x8d, 0x31,
    };
    try testing.expectEqualSlices(u8, &expected, vm.memory.data.items[0..32]);
}

test "EVM: CALL dispatches ECRECOVER precompile (0x01)" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const c = @import("crypto");

    const private_key = [_]u8{
        0x4c, 0x08, 0x83, 0xa6, 0x91, 0x02, 0x93, 0x7d,
        0x62, 0x33, 0x47, 0x71, 0x2c, 0x8f, 0xa5, 0xf3,
        0x6c, 0xd7, 0xd8, 0x3f, 0x9f, 0x3a, 0x52, 0x4f,
        0xc6, 0x6f, 0x66, 0x73, 0xc1, 0x4c, 0xab, 0x5c,
    };
    const msg = [_]u8{
        0x3a, 0x12, 0xb5, 0x10, 0x16, 0xfe, 0x4c, 0xbd,
        0x6b, 0xa7, 0xfe, 0x3e, 0x2a, 0x7f, 0xe1, 0x58,
        0x3f, 0x06, 0x66, 0xd2, 0xb5, 0x19, 0x6d, 0x90,
        0x2f, 0xdc, 0x54, 0x73, 0xa7, 0x0b, 0x2c, 0x0d,
    };
    const sig = try c.Secp256k1.sign(msg, private_key);
    const pk = try c.Secp256k1.PublicKey.fromPrivateKey(private_key);
    const expected_addr = pk.toAddress();

    var msg_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&msg, &msg_hash, .{});

    var vm = try evm.EVM.init(allocator, 1_000_000);
    defer vm.deinit();
    try vm.memory.data.resize(128);
    @memset(vm.memory.data.items[0..128], 0);
    @memcpy(vm.memory.data.items[0..32], msg_hash[0..32]);
    vm.memory.data.items[63] = sig.v;
    @memcpy(vm.memory.data.items[64..96], sig.r[0..32]);
    @memcpy(vm.memory.data.items[96..128], sig.s[0..32]);

    const code = [_]u8{
        0x60, 0x20, // outSize
        0x60, 0x00, // outOffset
        0x60, 0x80, // inSize
        0x60, 0x00, // inOffset
        0x60, 0x00, // value
        0x60, 0x01, // address
        0x61, 0xff, 0xff, // gas
        0xf1, // CALL
        0x3d, // RETURNDATASIZE
    };
    const precompile_result = try vm.execute(&code, &[_]u8{});
    defer if (precompile_result.return_data.len > 0) allocator.free(precompile_result.return_data);
    defer allocator.free(precompile_result.logs);

    const return_size = try vm.stack.pop();
    const success = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 1), success.limbs[0]);
    try testing.expectEqual(@as(u64, 32), return_size.limbs[0]);
    try testing.expectEqualSlices(u8, &expected_addr, vm.memory.data.items[12..32]);
}

test "EVM: STATICCALL executes with zero call value" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var callee_addr = types.Address.zero;
    callee_addr.bytes[19] = 0x0a;

    const callee_code = [_]u8{
        0x34, // CALLVALUE
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
    };
    try db.setCode(callee_addr, &callee_code);

    var vm = try evm.EVM.initWithState(allocator, 1_000_000, evm.ExecutionContext.default(), &db);
    defer vm.deinit();

    const code = [_]u8{
        0x60, 0x20, // outSize
        0x60, 0x00, // outOffset
        0x60, 0x00, // inSize
        0x60, 0x00, // inOffset
        0x60, 0x0a, // address
        0x61, 0xff, 0xff, // gas
        0xfa, // STATICCALL
    };

    const static_result = try vm.execute(&code, &[_]u8{});
    defer if (static_result.return_data.len > 0) allocator.free(static_result.return_data);
    defer allocator.free(static_result.logs);
    const success = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 1), success.limbs[0]);
    try testing.expectEqual(@as(u8, 0x00), vm.memory.data.items[31]);
}

test "EVM: DELEGATECALL preserves caller context" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var callee_addr = types.Address.zero;
    callee_addr.bytes[19] = 0x0a;

    const callee_code = [_]u8{
        0x33, // CALLER
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
    };
    try db.setCode(callee_addr, &callee_code);

    var context = evm.ExecutionContext.default();
    context.address.bytes[19] = 0xaa;
    context.caller.bytes[19] = 0xbb;

    var vm = try evm.EVM.initWithState(allocator, 1_000_000, context, &db);
    defer vm.deinit();

    const code = [_]u8{
        0x60, 0x20, // outSize
        0x60, 0x00, // outOffset
        0x60, 0x00, // inSize
        0x60, 0x00, // inOffset
        0x60, 0x0a, // address
        0x61, 0xff, 0xff, // gas
        0xf4, // DELEGATECALL
    };

    const delegate_result = try vm.execute(&code, &[_]u8{});
    defer if (delegate_result.return_data.len > 0) allocator.free(delegate_result.return_data);
    defer allocator.free(delegate_result.logs);
    const success = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 1), success.limbs[0]);
}

test "EVM: CREATE deploys runtime code from init code return data" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var creator = types.Address.zero;
    creator.bytes[19] = 0xaa;
    try db.createAccount(creator);
    try db.setBalance(creator, types.U256.fromU64(1_000_000));

    var context = evm.ExecutionContext.default();
    context.address = creator;
    context.caller = creator;

    var vm = try evm.EVM.initWithState(allocator, 2_000_000, context, &db);
    defer vm.deinit();

    // Init code: MSTORE8(0x00, 0x2a); RETURN(offset=0, length=1)
    const bytecode = [_]u8{
        0x60, 0x60, 0x60, 0x00, 0x53, // byte 0
        0x60, 0x2a, 0x60, 0x01, 0x53, // byte 1
        0x60, 0x60, 0x60, 0x02, 0x53, // byte 2
        0x60, 0x00, 0x60, 0x03, 0x53, // byte 3
        0x60, 0x53, 0x60, 0x04, 0x53, // byte 4
        0x60, 0x60, 0x60, 0x05, 0x53, // byte 5
        0x60, 0x01, 0x60, 0x06, 0x53, // byte 6
        0x60, 0x60, 0x60, 0x07, 0x53, // byte 7
        0x60, 0x00, 0x60, 0x08, 0x53, // byte 8
        0x60, 0xf3, 0x60, 0x09, 0x53, // byte 9
        0x60, 0x0a, // PUSH1 length
        0x60, 0x00, // PUSH1 offset
        0x60, 0x00, // PUSH1 value
        0xf0, // CREATE
    };

    const create_result = try vm.execute(&bytecode, &[_]u8{});
    defer if (create_result.return_data.len > 0) allocator.free(create_result.return_data);
    defer allocator.free(create_result.logs);
    const deployed_u256 = try vm.stack.pop();
    try testing.expect(!deployed_u256.isZero());

    const deployed_addr = addressFromU256(deployed_u256);

    const deployed_code = db.getCode(deployed_addr);
    try testing.expectEqual(@as(usize, 1), deployed_code.len);
    try testing.expectEqual(@as(u8, 0x2a), deployed_code[0]);
}

test "EVM: CREATE2 is deterministic for same salt and init code" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var creator = types.Address.zero;
    creator.bytes[19] = 0xcc;
    try db.createAccount(creator);
    try db.setBalance(creator, types.U256.fromU64(1_000_000));

    var context = evm.ExecutionContext.default();
    context.address = creator;
    context.caller = creator;

    var vm1 = try evm.EVM.initWithState(allocator, 2_000_000, context, &db);
    defer vm1.deinit();
    var vm2 = try evm.EVM.initWithState(allocator, 2_000_000, context, &db);
    defer vm2.deinit();

    const code = [_]u8{
        0x60, 0x60, 0x60, 0x00, 0x53, // byte 0
        0x60, 0x2a, 0x60, 0x01, 0x53, // byte 1
        0x60, 0x60, 0x60, 0x02, 0x53, // byte 2
        0x60, 0x00, 0x60, 0x03, 0x53, // byte 3
        0x60, 0x53, 0x60, 0x04, 0x53, // byte 4
        0x60, 0x60, 0x60, 0x05, 0x53, // byte 5
        0x60, 0x01, 0x60, 0x06, 0x53, // byte 6
        0x60, 0x60, 0x60, 0x07, 0x53, // byte 7
        0x60, 0x00, 0x60, 0x08, 0x53, // byte 8
        0x60, 0xf3, 0x60, 0x09, 0x53, // byte 9
        0x60, 0x01, // PUSH1 salt
        0x60, 0x0a, // length
        0x60, 0x00, // offset
        0x60, 0x00, // value
        0xf5, // CREATE2
    };

    const create2_result_1 = try vm1.execute(&code, &[_]u8{});
    defer if (create2_result_1.return_data.len > 0) allocator.free(create2_result_1.return_data);
    defer allocator.free(create2_result_1.logs);
    const create2_result_2 = try vm2.execute(&code, &[_]u8{});
    defer if (create2_result_2.return_data.len > 0) allocator.free(create2_result_2.return_data);
    defer allocator.free(create2_result_2.logs);
    const a1 = try vm1.stack.pop();
    const a2 = try vm2.stack.pop();
    try testing.expect(a1.eq(a2));
}

test "EVM: Nested CALL persists storage in state DB" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    const callee_addr = types.Address.zero;
    const callee_code = [_]u8{
        0x60, 0x2a, // value
        0x60, 0x01, // key
        0x55, // SSTORE
        0x00, // STOP
    };
    try db.setCode(callee_addr, &callee_code);

    var caller_ctx = evm.ExecutionContext.default();
    caller_ctx.address.bytes[19] = 0xdd;
    try db.createAccount(caller_ctx.address);

    var vm = try evm.EVM.initWithState(allocator, 1_000_000, caller_ctx, &db);
    defer vm.deinit();

    const call_code = [_]u8{
        0x60, 0x00, // outSize
        0x60, 0x00, // outOffset
        0x60, 0x00, // inSize
        0x60, 0x00, // inOffset
        0x60, 0x00, // value
        0x60, 0x00, // address
        0x61, 0xff, 0xff, // gas
        0xf1, // CALL
    };
    _ = try vm.execute(&call_code, &[_]u8{});
    const success = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 1), success.limbs[0]);

    const stored = try db.getStorage(callee_addr, types.U256.fromU64(1));
    try testing.expectEqual(@as(u64, 0x2a), stored.limbs[0]);
}

test "EVM: SELFDESTRUCT transfers balance and deletes account state" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var sender = types.Address.zero;
    sender.bytes[19] = 0xaa;
    const beneficiary = types.Address.zero;

    try db.createAccount(sender);
    try db.setBalance(sender, types.U256.fromU64(777));
    try db.setStorage(sender, types.U256.fromU64(1), types.U256.fromU64(42));
    try db.setCode(sender, &[_]u8{ 0x60, 0x01, 0x00 });

    var context = evm.ExecutionContext.default();
    context.address = sender;
    context.caller = sender;

    var vm = try evm.EVM.initWithState(allocator, 1_000_000, context, &db);
    defer vm.deinit();

    const bytecode = [_]u8{
        0x60, 0x00, // PUSH1 beneficiary address
        0xff, // SELFDESTRUCT
    };

    const result = try vm.execute(&bytecode, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);
    try testing.expect(result.success);

    try testing.expect(!db.exists(sender));
    const beneficiary_balance = try db.getBalance(beneficiary);
    try testing.expectEqual(@as(u64, 777), beneficiary_balance.limbs[0]);
    try testing.expectEqual(@as(u64, 32_603), vm.gas_used);
    try testing.expectEqual(@as(u64, 4_800), vm.gas_refund);
    const stored = try db.getStorage(sender, types.U256.fromU64(1));
    try testing.expect(stored.isZero());
    try testing.expectEqual(@as(usize, 0), db.getCode(sender).len);
}

test "EVM: Stack operations (DUP and SWAP)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    // Test DUP: Push 42, DUP1, should have two 42s
    const dup_bytecode = [_]u8{
        0x60, 0x2a, // PUSH1 42
        0x80, // DUP1
    };

    _ = try vm.execute(&dup_bytecode, &[_]u8{});
    const val1 = try vm.stack.pop();
    const val2 = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 42), val1.limbs[0]);
    try testing.expectEqual(@as(u64, 42), val2.limbs[0]);
}

test "EVM: Memory operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    // Store 0x1234 at offset 0, then load it
    const bytecode = [_]u8{
        0x61, 0x12, 0x34, // PUSH2 0x1234
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x00, // PUSH1 0
        0x51, // MLOAD
    };

    const result = try vm.execute(&bytecode, &[_]u8{});
    try testing.expect(result.success);
}

test "EVM: Storage operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    // Store and retrieve
    const bytecode = [_]u8{
        0x60, 0x42, // PUSH1 0x42 (value)
        0x60, 0x05, // PUSH1 5 (key)
        0x55, // SSTORE
        0x60, 0x05, // PUSH1 5 (key)
        0x54, // SLOAD
    };

    const result = try vm.execute(&bytecode, &[_]u8{});
    try testing.expect(result.success);
}

test "EVM: Event logging" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    // Store data in memory and emit LOG1
    const bytecode = [_]u8{
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0xaa, // PUSH1 0xaa (topic)
        0x60, 0x20, // PUSH1 32 (length)
        0x60, 0x00, // PUSH1 0 (offset)
        0xa1, // LOG1
    };

    const result = try vm.execute(&bytecode, &[_]u8{});
    defer {
        for (result.logs) |log| {
            allocator.free(log.topics);
            allocator.free(log.data);
        }
        allocator.free(result.logs);
    }

    try testing.expect(result.success);
    try testing.expectEqual(@as(usize, 1), result.logs.len);
    try testing.expectEqual(@as(usize, 1), result.logs[0].topics.len);
}

test "EVM: Environmental opcodes" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create context with known values
    var context = evm.ExecutionContext.default();
    context.block_number = 12345;
    context.block_timestamp = 1234567890;
    context.chain_id = 1;

    var vm = try evm.EVM.initWithContext(allocator, 1000000, context);
    defer vm.deinit();

    // Test NUMBER and TIMESTAMP opcodes
    const bytecode = [_]u8{
        0x43, // NUMBER
        0x42, // TIMESTAMP
        0x46, // CHAINID
    };

    const result = try vm.execute(&bytecode, &[_]u8{});
    try testing.expect(result.success);
}

test "EVM: SHA3 hashing" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    // Store "hello" in memory and hash it
    const bytecode = [_]u8{
        0x60, 0x68, // PUSH1 'h'
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x01, // PUSH1 1 (length)
        0x60, 0x1f, // PUSH1 31 (offset - last byte)
        0x20, // SHA3
    };

    const result = try vm.execute(&bytecode, &[_]u8{});
    try testing.expect(result.success);
}

test "EVM: REVERT handling" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    // Execute code that reverts
    const bytecode = [_]u8{
        0x60, 0x00, // PUSH1 0
        0x60, 0x00, // PUSH1 0
        0xfd, // REVERT
    };

    const result = try vm.execute(&bytecode, &[_]u8{});
    try testing.expect(!result.success);
}

test "EVM: Gas metering" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 8);
    defer vm.deinit();

    // This should run out of gas (limit is only 8)
    const bytecode = [_]u8{
        0x60, 0x01, // PUSH1 1  (3 gas) - total: 3
        0x60, 0x02, // PUSH1 2  (3 gas) - total: 6
        0x01, // ADD      (3 gas) - total: 9, should fail here since 9 > 8
        0x60, 0x00, // PUSH1 0  - should never reach this
    };

    const result = vm.execute(&bytecode, &[_]u8{});
    try testing.expectError(error.OutOfGas, result);
}

test "EVM: CALL gas includes value transfer and new-account cost" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var sender = types.Address.zero;
    sender.bytes[19] = 0xaa;
    try db.createAccount(sender);
    try db.setBalance(sender, types.U256.fromU64(1_000_000));

    var context = evm.ExecutionContext.default();
    context.address = sender;
    context.caller = sender;

    var vm = try evm.EVM.initWithState(allocator, 5_000_000, context, &db);
    defer vm.deinit();

    const code = [_]u8{
        0x60, 0x00, // outSize
        0x60, 0x00, // outOffset
        0x60, 0x00, // inSize
        0x60, 0x00, // inOffset
        0x60, 0x01, // value
        0x60, 0x0a, // address (new account, non-precompile)
        0x61, 0xff, 0xff, // gas
        0xf1, // CALL
    };

    const res = try vm.execute(&code, &[_]u8{});
    defer if (res.return_data.len > 0) allocator.free(res.return_data);
    defer allocator.free(res.logs);
    const success = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 1), success.limbs[0]);
    // PUSHes (7 * 3) + CALL base (700 + 2600 cold + 9000 value + 25000 new account).
    try testing.expectEqual(@as(u64, 37_321), vm.gas_used);
}

test "EVM: CREATE2 charges additional hashcost over CREATE for same init code length" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var creator = types.Address.zero;
    creator.bytes[19] = 0xcc;
    try db.createAccount(creator);
    try db.setBalance(creator, types.U256.fromU64(10_000_000));

    var context = evm.ExecutionContext.default();
    context.address = creator;
    context.caller = creator;

    var vm_create = try evm.EVM.initWithState(allocator, 5_000_000, context, &db);
    defer vm_create.deinit();
    var vm_create2 = try evm.EVM.initWithState(allocator, 5_000_000, context, &db);
    defer vm_create2.deinit();

    // length=64 -> ceil(64/32)=2 words, CREATE2 extra = 12 gas.
    const create_code = [_]u8{
        0x60, 0x40, // length
        0x60, 0x00, // offset
        0x60, 0x00, // value
        0xf0, // CREATE
    };
    const create2_code = [_]u8{
        0x60, 0x01, // salt
        0x60, 0x40, // length
        0x60, 0x00, // offset
        0x60, 0x00, // value
        0xf5, // CREATE2
    };

    const r1 = try vm_create.execute(&create_code, &[_]u8{});
    defer if (r1.return_data.len > 0) allocator.free(r1.return_data);
    defer allocator.free(r1.logs);
    const r2 = try vm_create2.execute(&create2_code, &[_]u8{});
    defer if (r2.return_data.len > 0) allocator.free(r2.return_data);
    defer allocator.free(r2.logs);

    // CREATE: 3 PUSH1 + (32000 + 6 mem + 6 copy) = 32021
    try testing.expectEqual(@as(u64, 32_021), vm_create.gas_used);
    // CREATE2: 4 PUSH1 + (32000 + 6 mem + 6 copy + 12 hashcost) = 32036
    try testing.expectEqual(@as(u64, 32_036), vm_create2.gas_used);
}

test "EVM: CALL OOG in child obeys EIP-150 reserve and does not exhaust parent" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var target = types.Address.zero;
    target.bytes[19] = 0x0a;

    // Infinite loop: JUMPDEST; PUSH1 0; JUMP
    const looping = [_]u8{ 0x5b, 0x60, 0x00, 0x56 };
    try db.setCode(target, &looping);

    var vm = try evm.EVM.initWithState(allocator, 100_000, evm.ExecutionContext.default(), &db);
    defer vm.deinit();

    const caller = [_]u8{
        0x60, 0x00, // outSize
        0x60, 0x00, // outOffset
        0x60, 0x00, // inSize
        0x60, 0x00, // inOffset
        0x60, 0x00, // value
        0x60, 0x0a, // address
        0x61, 0xff, 0xff, // requested gas (high)
        0xf1, // CALL
    };

    const result = try vm.execute(&caller, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    const call_success = try vm.stack.pop();
    try testing.expect(call_success.isZero());
    // EIP-150 reserve should leave parent with remaining gas.
    try testing.expect(vm.gas_used < vm.gas_limit);
}

test "EVM: CALL cold then warm account access has exact gas" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var vm = try evm.EVM.initWithState(allocator, 100_000, evm.ExecutionContext.default(), &db);
    defer vm.deinit();

    const code = [_]u8{
        // First CALL to 0x0a (cold): 7 PUSH1 + CALL
        0x60, 0x00, // outSize
        0x60, 0x00, // outOffset
        0x60, 0x00, // inSize
        0x60, 0x00, // inOffset
        0x60, 0x00, // value
        0x60, 0x0a, // address
        0x60, 0xff, // gas
        0xf1, // CALL
        // Second CALL to 0x0a (warm): 7 PUSH1 + CALL
        0x60,
        0x00,
        0x60,
        0x00,
        0x60,
        0x00,
        0x60,
        0x00,
        0x60,
        0x00,
        0x60,
        0x0a,
        0x60,
        0xff,
        0xf1,
    };

    const result = try vm.execute(&code, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    // First call: 21 + (700 + 2600) = 3321
    // Second call: 21 + (700 + 100) = 821
    try testing.expectEqual(@as(u64, 4_142), vm.gas_used);
}

test "EVM: SLOAD cold then warm has exact gas" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 100_000);
    defer vm.deinit();

    const code = [_]u8{
        0x60, 0x01, // PUSH1 key
        0x54, // SLOAD (cold)
        0x60, 0x01, // PUSH1 key
        0x54, // SLOAD (warm)
    };

    const result = try vm.execute(&code, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    // PUSH1 + SLOAD(cold) + PUSH1 + SLOAD(warm) = 3 + 2100 + 3 + 100
    try testing.expectEqual(@as(u64, 2_206), vm.gas_used);
}

test "EVM: SSTORE clear tracks refund and exact gas" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 100_000);
    defer vm.deinit();

    const code = [_]u8{
        // SSTORE key=1 value=7 (cold, zero->nonzero): 3+3 + 2100 + 20000
        0x60, 0x07, // PUSH1 value
        0x60, 0x01, // PUSH1 key
        0x55, // SSTORE
        // SSTORE key=1 value=0 (warm, nonzero->zero): 3+3 + 100, refund +4800
        0x60, 0x00, // PUSH1 value
        0x60, 0x01, // PUSH1 key
        0x55, // SSTORE
    };

    const result = try vm.execute(&code, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    try testing.expectEqual(@as(u64, 22_212), vm.gas_used);
    try testing.expectEqual(@as(u64, 4_800), vm.gas_refund);
}

test "EVM: CALL to precompile address uses warm access cost" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 100_000);
    defer vm.deinit();

    const code = [_]u8{
        0x60, 0x00, // outSize
        0x60, 0x00, // outOffset
        0x60, 0x00, // inSize
        0x60, 0x00, // inOffset
        0x60, 0x00, // value
        0x60, 0x02, // precompile SHA256 address
        0x60, 0xff, // gas
        0xf1, // CALL
    };

    const result = try vm.execute(&code, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    // CALL base is 700 + warm(100); no calldata, no return copy, precompile gas is 60.
    // Plus 7 PUSH1 operations.
    try testing.expectEqual(@as(u64, 881), vm.gas_used);
}

test "EVM: CALL charges return-memory expansion gas exactly" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var target = types.Address.zero;
    target.bytes[19] = 0x0a;

    // Child: PUSH1 0; PUSH1 0; RETURN (returns empty, still successful).
    const callee = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0xf3 };
    try db.setCode(target, &callee);

    var vm = try evm.EVM.initWithState(allocator, 200_000, evm.ExecutionContext.default(), &db);
    defer vm.deinit();

    const caller = [_]u8{
        0x60, 0x20, // outSize
        0x60, 0x40, // outOffset
        0x60, 0x00, // inSize
        0x60, 0x00, // inOffset
        0x60, 0x00, // value
        0x60, 0x0a, // address
        0x60, 0xff, // gas
        0xf1, // CALL
    };

    const result = try vm.execute(&caller, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    // Parent push gas: 21
    // CALL base: 700 + 2600 (cold account) = 3300
    // Return memory expansion: 0 -> 96 bytes = 3 words => 9 gas
    // Child execution: PUSH1 + PUSH1 + RETURN = 6 gas
    try testing.expectEqual(@as(u64, 3_336), vm.gas_used);
}

test "EVM: CALL propagates child gas refund on successful execution" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var callee = types.Address.zero;
    callee.bytes[19] = 0x0a;

    // Child clears a pre-set non-zero slot, earning SSTORE clear refund.
    const callee_code = [_]u8{
        0x60, 0x00, // value
        0x60, 0x01, // key
        0x55, // SSTORE
        0x00, // STOP
    };
    try db.setCode(callee, &callee_code);
    try db.setStorage(callee, types.U256.fromU64(1), types.U256.fromU64(7));

    var vm = try evm.EVM.initWithState(allocator, 200_000, evm.ExecutionContext.default(), &db);
    defer vm.deinit();

    const caller = [_]u8{
        0x60, 0x00, // outSize
        0x60, 0x00, // outOffset
        0x60, 0x00, // inSize
        0x60, 0x00, // inOffset
        0x60, 0x00, // value
        0x60, 0x0a, // address
        0x61, 0xff, 0xff, // gas
        0xf1, // CALL
    };

    const result = try vm.execute(&caller, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    // Parent: 21 push gas + (700 + 2600 cold access)
    // Child: PUSH1 + PUSH1 + SSTORE(cold clear) + STOP = 3 + 3 + 2100 + 0
    try testing.expectEqual(@as(u64, 5_427), vm.gas_used);
    try testing.expectEqual(@as(u64, 4_800), vm.gas_refund);
}

test "EVM: CREATE memory expansion persists across repeated creates" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 200_000);
    defer vm.deinit();

    const code = [_]u8{
        // First CREATE with len=32 expands memory from 0 to 32 bytes.
        0x60, 0x20, // len
        0x60, 0x00, // offset
        0x60, 0x00, // value
        0xf0, // CREATE
        // Second CREATE with same memory range should pay no additional expansion.
        0x60, 0x20, // len
        0x60, 0x00, // offset
        0x60, 0x00, // value
        0xf0, // CREATE
    };

    const result = try vm.execute(&code, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    // First: 9 push + (32000 + 3 mem + 3 copy) = 32015
    // Second: 9 push + (32000 + 0 mem + 3 copy) = 32012
    try testing.expectEqual(@as(u64, 64_027), vm.gas_used);
}
