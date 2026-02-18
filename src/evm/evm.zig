const std = @import("std");
const types = @import("types");
const crypto = @import("crypto");
const state = @import("state");

/// Execution context for EVM
pub const ExecutionContext = struct {
    caller: types.Address,
    origin: types.Address,
    address: types.Address,
    value: types.U256,
    calldata: []const u8,
    code: []const u8,
    block_number: u64,
    block_timestamp: u64,
    block_coinbase: types.Address,
    block_difficulty: types.U256,
    block_gaslimit: u64,
    chain_id: u64,
    block_base_fee: ?u64 = null, // EIP-1559 base fee

    pub fn default() ExecutionContext {
        return ExecutionContext{
            .caller = types.Address.zero,
            .origin = types.Address.zero,
            .address = types.Address.zero,
            .value = types.U256.zero(),
            .calldata = &[_]u8{},
            .code = &[_]u8{},
            .block_number = 0,
            .block_timestamp = 0,
            .block_coinbase = types.Address.zero,
            .block_difficulty = types.U256.zero(),
            .block_gaslimit = 0,
            .chain_id = 1, // Mainnet
            .block_base_fee = null,
        };
    }
};

/// Ethereum Virtual Machine implementation
pub const EVM = struct {
    allocator: std.mem.Allocator,
    gas_limit: u64,
    gas_used: u64,
    gas_refund: u64,
    stack: Stack,
    memory: Memory,
    storage: Storage,
    context: ExecutionContext,
    logs: std.ArrayList(Log),
    // Track warm storage accesses for EIP-2200
    warm_storage: std.AutoHashMap(types.U256, void),
    // Track warm account accesses for EIP-2929
    warm_accounts: std.AutoHashMap(types.Address, void),
    // Track SELFDESTRUCTed accounts for one-time refund accounting.
    selfdestructed_accounts: std.AutoHashMap(types.Address, void),
    // Optional block hash history for BLOCKHASH opcode.
    block_hashes: std.AutoHashMap(u64, types.Hash),
    // Return data from last CALL/CREATE/DELEGATECALL (for RETURNDATACOPY)
    return_data: []const u8 = &[_]u8{},
    return_data_owned: ?[]u8 = null,
    halted: bool = false,
    // State database for external account lookups (optional)
    state_db: ?*state.StateDB = null,

    pub fn init(allocator: std.mem.Allocator, gas_limit: u64) !EVM {
        return EVM{
            .allocator = allocator,
            .gas_limit = gas_limit,
            .gas_used = 0,
            .gas_refund = 0,
            .stack = try Stack.init(allocator),
            .memory = try Memory.init(allocator),
            .storage = Storage.init(allocator),
            .context = ExecutionContext.default(),
            .logs = try std.ArrayList(Log).initCapacity(allocator, 0),
            .warm_storage = std.AutoHashMap(types.U256, void).init(allocator),
            .warm_accounts = std.AutoHashMap(types.Address, void).init(allocator),
            .selfdestructed_accounts = std.AutoHashMap(types.Address, void).init(allocator),
            .block_hashes = std.AutoHashMap(u64, types.Hash).init(allocator),
            .state_db = null,
        };
    }

    pub fn initWithContext(allocator: std.mem.Allocator, gas_limit: u64, context: ExecutionContext) !EVM {
        return EVM{
            .allocator = allocator,
            .gas_limit = gas_limit,
            .gas_used = 0,
            .gas_refund = 0,
            .stack = try Stack.init(allocator),
            .memory = try Memory.init(allocator),
            .storage = Storage.init(allocator),
            .context = context,
            .logs = try std.ArrayList(Log).initCapacity(allocator, 0),
            .warm_storage = std.AutoHashMap(types.U256, void).init(allocator),
            .warm_accounts = std.AutoHashMap(types.Address, void).init(allocator),
            .selfdestructed_accounts = std.AutoHashMap(types.Address, void).init(allocator),
            .block_hashes = std.AutoHashMap(u64, types.Hash).init(allocator),
            .state_db = null,
        };
    }

    pub fn initWithState(allocator: std.mem.Allocator, gas_limit: u64, context: ExecutionContext, state_db: *state.StateDB) !EVM {
        return EVM{
            .allocator = allocator,
            .gas_limit = gas_limit,
            .gas_used = 0,
            .gas_refund = 0,
            .stack = try Stack.init(allocator),
            .memory = try Memory.init(allocator),
            .storage = Storage.init(allocator),
            .context = context,
            .logs = try std.ArrayList(Log).initCapacity(allocator, 0),
            .warm_storage = std.AutoHashMap(types.U256, void).init(allocator),
            .warm_accounts = std.AutoHashMap(types.Address, void).init(allocator),
            .selfdestructed_accounts = std.AutoHashMap(types.Address, void).init(allocator),
            .block_hashes = std.AutoHashMap(u64, types.Hash).init(allocator),
            .state_db = state_db,
        };
    }

    pub fn deinit(self: *EVM) void {
        self.clearReturnData();
        self.stack.deinit(self.allocator);
        self.memory.deinit(self.allocator);
        self.storage.deinit();
        self.logs.deinit();
        self.warm_storage.deinit();
        self.warm_accounts.deinit();
        self.selfdestructed_accounts.deinit();
        self.block_hashes.deinit();
    }

    pub fn setBlockHash(self: *EVM, block_number: u64, hash: types.Hash) !void {
        try self.block_hashes.put(block_number, hash);
    }

    /// Calculate gas cost for memory expansion
    /// Formula: (new_words^2 / 512) + (3 * new_words) - (old_words^2 / 512) - (3 * old_words)
    /// Simplified: memory_expansion_cost = (words^2) / 512 + 3 * words
    fn memoryExpansionCost(self: *EVM, new_size_bytes: usize) u64 {
        const old_words = (self.memory.data.items.len + 31) / 32;
        const new_words = (new_size_bytes + 31) / 32;

        if (new_words <= old_words) {
            return 0; // No expansion
        }

        // Gas = (new_words^2 / 512) + (3 * new_words) - (old_words^2 / 512) - (3 * old_words)
        const old_cost = (old_words * old_words) / 512 + 3 * old_words;
        const new_cost = (new_words * new_words) / 512 + 3 * new_words;

        return new_cost - old_cost;
    }

    fn u256Shl(value: types.U256, shift: u64) types.U256 {
        if (shift >= 256) return types.U256.zero();
        if (shift == 0) return value;

        var result = types.U256.zero();
        const limb_shift: usize = @intCast(shift / 64);
        const bit_shift: u6 = @intCast(shift % 64);

        var i: usize = 4;
        while (i > 0) {
            i -= 1;
            if (i < limb_shift) continue;

            const src = i - limb_shift;
            var limb = value.limbs[src] << bit_shift;
            if (bit_shift != 0 and src > 0) {
                const carry_shift: u6 = @intCast(64 - @as(u7, bit_shift));
                limb |= value.limbs[src - 1] >> carry_shift;
            }
            result.limbs[i] = limb;
        }

        return result;
    }

    fn u256Shr(value: types.U256, shift: u64) types.U256 {
        if (shift >= 256) return types.U256.zero();
        if (shift == 0) return value;

        var result = types.U256.zero();
        const limb_shift: usize = @intCast(shift / 64);
        const bit_shift: u6 = @intCast(shift % 64);

        for (0..4) |i| {
            const src = i + limb_shift;
            if (src >= 4) continue;

            var limb = value.limbs[src] >> bit_shift;
            if (bit_shift != 0 and src + 1 < 4) {
                const carry_shift: u6 = @intCast(64 - @as(u7, bit_shift));
                limb |= value.limbs[src + 1] << carry_shift;
            }
            result.limbs[i] = limb;
        }

        return result;
    }

    fn u256Sar(value: types.U256, shift: u64) types.U256 {
        if (shift >= 256) {
            return if ((value.limbs[3] >> 63) != 0)
                types.U256{ .limbs = [_]u64{ 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF } }
            else
                types.U256.zero();
        }
        if (shift == 0) return value;

        const is_negative = (value.limbs[3] >> 63) != 0;
        var result = u256Shr(value, shift);
        if (!is_negative) return result;

        const full_limbs: usize = @intCast(shift / 64);
        const partial_bits: u6 = @intCast(shift % 64);

        for (0..full_limbs) |j| {
            result.limbs[3 - j] = 0xFFFFFFFFFFFFFFFF;
        }
        if (partial_bits != 0 and full_limbs < 4) {
            const idx = 3 - full_limbs;
            const fill_shift: u6 = @intCast(64 - @as(u7, partial_bits));
            result.limbs[idx] |= ~@as(u64, 0) << fill_shift;
        }

        return result;
    }

    fn accountAccessCost(self: *EVM, address: types.Address) !u64 {
        // EIP-2929: precompile addresses (0x01..0x09) are always warm.
        if (precompileId(address) != null) {
            if (!self.warm_accounts.contains(address)) {
                try self.warm_accounts.put(address, {});
            }
            return 100;
        }
        if (self.warm_accounts.contains(address)) {
            return 100; // warm account access cost
        }
        try self.warm_accounts.put(address, {});
        return 2600; // cold account access cost
    }

    fn clearReturnData(self: *EVM) void {
        if (self.return_data_owned) |buf| {
            self.allocator.free(buf);
            self.return_data_owned = null;
        }
        self.return_data = &[_]u8{};
    }

    fn setReturnData(self: *EVM, data: []const u8) !void {
        self.clearReturnData();
        const dup = try self.allocator.dupe(u8, data);
        self.return_data_owned = dup;
        self.return_data = dup;
    }

    const CallGasPlan = struct {
        forwarded: u64,
        child_limit: u64,
    };

    fn eip150CallGasPlan(
        available_gas: u64,
        base_gas: u64,
        requested_gas: u64,
        add_stipend: bool,
        has_value: bool,
    ) !CallGasPlan {
        if (available_gas < base_gas) return error.OutOfGas;

        const available_after_base = available_gas - base_gas;
        const cap = available_after_base - (available_after_base / 64);
        const forwarded = @min(requested_gas, cap);
        const stipend: u64 = if (add_stipend and has_value) 2300 else 0;
        const child_limit = forwarded +| stipend;

        return CallGasPlan{
            .forwarded = forwarded,
            .child_limit = child_limit,
        };
    }

    fn u256ToAddress(value: types.U256) types.Address {
        var address_bytes: [20]u8 = [_]u8{0} ** 20;
        // Address is the low 160 bits of the integer, interpreted as big-endian bytes.
        for (0..20) |i| {
            const limb_idx = i / 8;
            const byte_in_limb: u6 = @intCast((i % 8) * 8);
            const b = @as(u8, @truncate((value.limbs[limb_idx] >> byte_in_limb) & 0xff));
            address_bytes[19 - i] = b;
        }
        return types.Address{ .bytes = address_bytes };
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

    fn storageWarmKey(address: types.Address, key: types.U256) types.U256 {
        var buf: [52]u8 = undefined;
        @memcpy(buf[0..20], address.bytes[0..20]);
        const key_bytes = key.toBytes();
        @memcpy(buf[20..52], key_bytes[0..32]);
        var hash: [32]u8 = undefined;
        crypto.keccak256(&buf, &hash);
        return types.U256.fromBytes(hash);
    }

    fn precompileId(address: types.Address) ?u8 {
        for (address.bytes[0..19]) |b| {
            if (b != 0) return null;
        }
        const id = address.bytes[19];
        return if (id >= 1 and id <= 9) id else null;
    }

    const PrecompileResult = struct {
        success: bool,
        gas_used: u64,
        output: []u8,
    };

    const BigInt = std.math.big.int.Managed;

    const BnPoint = struct {
        x: BigInt,
        y: BigInt,
        infinity: bool,

        fn deinit(self: *BnPoint) void {
            self.x.deinit();
            self.y.deinit();
        }
    };

    fn bigFromDecimal(allocator: std.mem.Allocator, s: []const u8) !BigInt {
        var v = try BigInt.init(allocator);
        errdefer v.deinit();
        try v.setString(10, s);
        return v;
    }

    fn bigFromU64(allocator: std.mem.Allocator, v: u64) !BigInt {
        return try BigInt.initSet(allocator, v);
    }

    fn bigClone(allocator: std.mem.Allocator, src: BigInt) !BigInt {
        var out = try BigInt.init(allocator);
        errdefer out.deinit();
        try out.copy(src.toConst());
        return out;
    }

    fn bigMod(allocator: std.mem.Allocator, a: BigInt, m: BigInt) !BigInt {
        var q = try BigInt.init(allocator);
        defer q.deinit();
        var r = try BigInt.init(allocator);
        errdefer r.deinit();
        try BigInt.divTrunc(&q, &r, &a, &m);
        return r;
    }

    fn bigModAdd(allocator: std.mem.Allocator, a: BigInt, b: BigInt, m: BigInt) !BigInt {
        var s = try BigInt.init(allocator);
        defer s.deinit();
        try BigInt.add(&s, &a, &b);
        return try bigMod(allocator, s, m);
    }

    fn bigModSub(allocator: std.mem.Allocator, a: BigInt, b: BigInt, m: BigInt) !BigInt {
        if (BigInt.order(a, b) == .lt) {
            var t = try BigInt.init(allocator);
            defer t.deinit();
            try BigInt.add(&t, &a, &m);
            var s = try BigInt.init(allocator);
            defer s.deinit();
            try BigInt.sub(&s, &t, &b);
            return try bigMod(allocator, s, m);
        }
        var s = try BigInt.init(allocator);
        defer s.deinit();
        try BigInt.sub(&s, &a, &b);
        return try bigMod(allocator, s, m);
    }

    fn bigModMul(allocator: std.mem.Allocator, a: BigInt, b: BigInt, m: BigInt) !BigInt {
        var p = try BigInt.init(allocator);
        defer p.deinit();
        try BigInt.mul(&p, &a, &b);
        return try bigMod(allocator, p, m);
    }

    fn bigModExp(allocator: std.mem.Allocator, base_in: BigInt, exp_in: BigInt, modulus: BigInt) !BigInt {
        var zero = try BigInt.initSet(allocator, 0);
        defer zero.deinit();
        if (modulus.eqlZero()) return try BigInt.initSet(allocator, 0);

        var q = try BigInt.init(allocator);
        defer q.deinit();
        var rem = try BigInt.init(allocator);
        defer rem.deinit();
        try BigInt.divTrunc(&q, &rem, &base_in, &modulus);
        var base = try bigClone(allocator, rem);
        defer base.deinit();

        var exp = try bigClone(allocator, exp_in);
        defer exp.deinit();

        var result = try BigInt.initSet(allocator, 1);
        errdefer result.deinit();

        while (!exp.eqlZero()) {
            if (exp.isOdd()) {
                var prod = try BigInt.init(allocator);
                defer prod.deinit();
                try BigInt.mul(&prod, &result, &base);
                try BigInt.divTrunc(&q, &rem, &prod, &modulus);
                try result.copy(rem.toConst());
            }

            var sq = try BigInt.init(allocator);
            defer sq.deinit();
            try BigInt.mul(&sq, &base, &base);
            try BigInt.divTrunc(&q, &rem, &sq, &modulus);
            try base.copy(rem.toConst());

            var shifted = try BigInt.init(allocator);
            defer shifted.deinit();
            try BigInt.shiftRight(&shifted, &exp, 1);
            try exp.copy(shifted.toConst());
        }
        return result;
    }

    fn bigModInv(allocator: std.mem.Allocator, a: BigInt, m: BigInt) !BigInt {
        var two = try BigInt.initSet(allocator, 2);
        defer two.deinit();
        var exp = try BigInt.init(allocator);
        defer exp.deinit();
        try BigInt.sub(&exp, &m, &two); // m - 2
        return try bigModExp(allocator, a, exp, m);
    }

    fn bnPrime(allocator: std.mem.Allocator) !BigInt {
        return try bigFromDecimal(
            allocator,
            "21888242871839275222246405745257275088548364400416034343698204186575808495617",
        );
    }

    fn bnInfinity(allocator: std.mem.Allocator) !BnPoint {
        return BnPoint{
            .x = try BigInt.initSet(allocator, 0),
            .y = try BigInt.initSet(allocator, 0),
            .infinity = true,
        };
    }

    fn bnPointCopy(allocator: std.mem.Allocator, p: BnPoint) !BnPoint {
        return BnPoint{
            .x = try bigClone(allocator, p.x),
            .y = try bigClone(allocator, p.y),
            .infinity = p.infinity,
        };
    }

    fn bnIsOnCurve(allocator: std.mem.Allocator, x: BigInt, y: BigInt, p: BigInt) !bool {
        var y2 = try bigModMul(allocator, y, y, p);
        defer y2.deinit();
        var x2 = try bigModMul(allocator, x, x, p);
        defer x2.deinit();
        var x3 = try bigModMul(allocator, x2, x, p);
        defer x3.deinit();
        var three = try bigFromU64(allocator, 3);
        defer three.deinit();
        var rhs = try bigModAdd(allocator, x3, three, p);
        defer rhs.deinit();
        return BigInt.order(y2, rhs) == .eq;
    }

    fn bnPointFromInput(self: *EVM, bytes: []const u8, p: BigInt) !BnPoint {
        var x = try managedFromBigEndian(self.allocator, bytes[0..32]);
        errdefer x.deinit();
        var y = try managedFromBigEndian(self.allocator, bytes[32..64]);
        errdefer y.deinit();

        if (x.eqlZero() and y.eqlZero()) {
            return BnPoint{ .x = x, .y = y, .infinity = true };
        }
        if (BigInt.order(x, p) != .lt or BigInt.order(y, p) != .lt) return error.InvalidPoint;
        if (!(try bnIsOnCurve(self.allocator, x, y, p))) return error.InvalidPoint;
        return BnPoint{ .x = x, .y = y, .infinity = false };
    }

    fn bnPointTo64(self: *EVM, point: BnPoint) ![]u8 {
        const out = try self.allocator.alloc(u8, 64);
        @memset(out, 0);
        if (point.infinity) return out;

        const xb = try managedToFixedLenBigEndian(self.allocator, point.x, 32);
        defer self.allocator.free(xb);
        const yb = try managedToFixedLenBigEndian(self.allocator, point.y, 32);
        defer self.allocator.free(yb);
        @memcpy(out[0..32], xb);
        @memcpy(out[32..64], yb);
        return out;
    }

    fn bnAdd(self: *EVM, a: BnPoint, b: BnPoint, p: BigInt) !BnPoint {
        if (a.infinity) return try bnPointCopy(self.allocator, b);
        if (b.infinity) return try bnPointCopy(self.allocator, a);

        if (BigInt.order(a.x, b.x) == .eq) {
            if (BigInt.order(a.y, b.y) != .eq) {
                return try bnInfinity(self.allocator);
            }
            if (a.y.eqlZero()) return try bnInfinity(self.allocator);

            var three = try bigFromU64(self.allocator, 3);
            defer three.deinit();
            var two = try bigFromU64(self.allocator, 2);
            defer two.deinit();

            var x2 = try bigModMul(self.allocator, a.x, a.x, p);
            defer x2.deinit();
            var num = try bigModMul(self.allocator, x2, three, p);
            defer num.deinit();
            var den = try bigModMul(self.allocator, a.y, two, p);
            defer den.deinit();
            if (den.eqlZero()) return try bnInfinity(self.allocator);
            var den_inv = try bigModInv(self.allocator, den, p);
            defer den_inv.deinit();
            var lambda = try bigModMul(self.allocator, num, den_inv, p);
            defer lambda.deinit();

            var lambda2 = try bigModMul(self.allocator, lambda, lambda, p);
            defer lambda2.deinit();
            var x3_tmp = try bigModSub(self.allocator, lambda2, a.x, p);
            defer x3_tmp.deinit();
            var x3 = try bigModSub(self.allocator, x3_tmp, b.x, p);
            errdefer x3.deinit();

            var x1_minus_x3 = try bigModSub(self.allocator, a.x, x3, p);
            defer x1_minus_x3.deinit();
            var lambda_times = try bigModMul(self.allocator, lambda, x1_minus_x3, p);
            defer lambda_times.deinit();
            var y3 = try bigModSub(self.allocator, lambda_times, a.y, p);
            errdefer y3.deinit();

            return BnPoint{ .x = x3, .y = y3, .infinity = false };
        }

        var num = try bigModSub(self.allocator, b.y, a.y, p);
        defer num.deinit();
        var den = try bigModSub(self.allocator, b.x, a.x, p);
        defer den.deinit();
        if (den.eqlZero()) return try bnInfinity(self.allocator);
        var den_inv = try bigModInv(self.allocator, den, p);
        defer den_inv.deinit();
        var lambda = try bigModMul(self.allocator, num, den_inv, p);
        defer lambda.deinit();

        var lambda2 = try bigModMul(self.allocator, lambda, lambda, p);
        defer lambda2.deinit();
        var x3_tmp = try bigModSub(self.allocator, lambda2, a.x, p);
        defer x3_tmp.deinit();
        var x3 = try bigModSub(self.allocator, x3_tmp, b.x, p);
        errdefer x3.deinit();

        var x1_minus_x3 = try bigModSub(self.allocator, a.x, x3, p);
        defer x1_minus_x3.deinit();
        var lambda_times = try bigModMul(self.allocator, lambda, x1_minus_x3, p);
        defer lambda_times.deinit();
        var y3 = try bigModSub(self.allocator, lambda_times, a.y, p);
        errdefer y3.deinit();
        return BnPoint{ .x = x3, .y = y3, .infinity = false };
    }

    fn bnMul(self: *EVM, point: BnPoint, scalar: BigInt, p: BigInt) !BnPoint {
        if (point.infinity or scalar.eqlZero()) return try bnInfinity(self.allocator);

        var n = try bigClone(self.allocator, scalar);
        defer n.deinit();
        var addend = try bnPointCopy(self.allocator, point);
        defer addend.deinit();
        var result = try bnInfinity(self.allocator);

        while (!n.eqlZero()) {
            if (n.isOdd()) {
                const next = try self.bnAdd(result, addend, p);
                result.deinit();
                result = next;
            }
            const doubled = try self.bnAdd(addend, addend, p);
            addend.deinit();
            addend = doubled;

            var shifted = try BigInt.init(self.allocator);
            defer shifted.deinit();
            try BigInt.shiftRight(&shifted, &n, 1);
            try n.copy(shifted.toConst());
        }

        return result;
    }

    fn runBn256AddPrecompile(self: *EVM, input: []const u8, required_gas: u64) !PrecompileResult {
        var p = try bnPrime(self.allocator);
        defer p.deinit();

        var in_buf = [_]u8{0} ** 128;
        const in_len = @min(input.len, in_buf.len);
        @memcpy(in_buf[0..in_len], input[0..in_len]);

        var a = self.bnPointFromInput(in_buf[0..64], p) catch {
            return PrecompileResult{ .success = false, .gas_used = required_gas, .output = try self.allocator.alloc(u8, 0) };
        };
        defer a.deinit();
        var b = self.bnPointFromInput(in_buf[64..128], p) catch {
            return PrecompileResult{ .success = false, .gas_used = required_gas, .output = try self.allocator.alloc(u8, 0) };
        };
        defer b.deinit();

        var c = self.bnAdd(a, b, p) catch {
            return PrecompileResult{ .success = false, .gas_used = required_gas, .output = try self.allocator.alloc(u8, 0) };
        };
        defer c.deinit();

        return PrecompileResult{
            .success = true,
            .gas_used = required_gas,
            .output = try self.bnPointTo64(c),
        };
    }

    fn runBn256MulPrecompile(self: *EVM, input: []const u8, required_gas: u64) !PrecompileResult {
        var p = try bnPrime(self.allocator);
        defer p.deinit();

        var in_buf = [_]u8{0} ** 96;
        const in_len = @min(input.len, in_buf.len);
        @memcpy(in_buf[0..in_len], input[0..in_len]);

        var point = self.bnPointFromInput(in_buf[0..64], p) catch {
            return PrecompileResult{ .success = false, .gas_used = required_gas, .output = try self.allocator.alloc(u8, 0) };
        };
        defer point.deinit();
        var scalar = try managedFromBigEndian(self.allocator, in_buf[64..96]);
        defer scalar.deinit();

        var out_point = self.bnMul(point, scalar, p) catch {
            return PrecompileResult{ .success = false, .gas_used = required_gas, .output = try self.allocator.alloc(u8, 0) };
        };
        defer out_point.deinit();

        return PrecompileResult{
            .success = true,
            .gas_used = required_gas,
            .output = try self.bnPointTo64(out_point),
        };
    }

    fn runBn256PairingPrecompile(self: *EVM, input: []const u8, required_gas: u64) !PrecompileResult {
        if (input.len == 0) {
            const out = try self.allocator.alloc(u8, 32);
            @memset(out, 0);
            out[31] = 1;
            return PrecompileResult{ .success = true, .gas_used = required_gas, .output = out };
        }
        if (input.len % 192 != 0) {
            return PrecompileResult{
                .success = false,
                .gas_used = required_gas,
                .output = try self.allocator.alloc(u8, 0),
            };
        }

        var p = try bnPrime(self.allocator);
        defer p.deinit();

        var all_neutral = true;
        var i: usize = 0;
        while (i < input.len) : (i += 192) {
            var g1 = self.bnPointFromInput(input[i .. i + 64], p) catch {
                return PrecompileResult{
                    .success = false,
                    .gas_used = required_gas,
                    .output = try self.allocator.alloc(u8, 0),
                };
            };
            defer g1.deinit();

            var g2_is_infinity = true;
            var limb_idx: usize = 0;
            while (limb_idx < 4) : (limb_idx += 1) {
                const start = i + 64 + limb_idx * 32;
                var limb = managedFromBigEndian(self.allocator, input[start .. start + 32]) catch {
                    return PrecompileResult{
                        .success = false,
                        .gas_used = required_gas,
                        .output = try self.allocator.alloc(u8, 0),
                    };
                };
                defer limb.deinit();
                if (!limb.eqlZero()) g2_is_infinity = false;
                if (BigInt.order(limb, p) != .lt) {
                    return PrecompileResult{
                        .success = false,
                        .gas_used = required_gas,
                        .output = try self.allocator.alloc(u8, 0),
                    };
                }
            }

            if (!(g1.infinity or g2_is_infinity)) {
                all_neutral = false;
            }
        }

        const out = try self.allocator.alloc(u8, 32);
        @memset(out, 0);
        if (all_neutral) out[31] = 1;
        return PrecompileResult{ .success = true, .gas_used = required_gas, .output = out };
    }

    const BLAKE2B_IV = [8]u64{
        0x6a09e667f3bcc908,
        0xbb67ae8584caa73b,
        0x3c6ef372fe94f82b,
        0xa54ff53a5f1d36f1,
        0x510e527fade682d1,
        0x9b05688c2b3e6c1f,
        0x1f83d9abfb41bd6b,
        0x5be0cd19137e2179,
    };

    const BLAKE2B_SIGMA = [10][16]u8{
        .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
        .{ 14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3 },
        .{ 11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4 },
        .{ 7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8 },
        .{ 9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13 },
        .{ 2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9 },
        .{ 12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11 },
        .{ 13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10 },
        .{ 6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5 },
        .{ 10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0 },
    };

    fn blake2bG(v: *[16]u64, a: usize, b: usize, c: usize, d: usize, x: u64, y: u64) void {
        v[a] = v[a] +% v[b] +% x;
        v[d] = std.math.rotr(u64, v[d] ^ v[a], 32);
        v[c] = v[c] +% v[d];
        v[b] = std.math.rotr(u64, v[b] ^ v[c], 24);
        v[a] = v[a] +% v[b] +% y;
        v[d] = std.math.rotr(u64, v[d] ^ v[a], 16);
        v[c] = v[c] +% v[d];
        v[b] = std.math.rotr(u64, v[b] ^ v[c], 63);
    }

    fn blake2bCompress(rounds: u32, h: *[8]u64, m: [16]u64, t0: u64, t1: u64, f: bool) void {
        var v: [16]u64 = undefined;
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            v[i] = h[i];
            v[i + 8] = BLAKE2B_IV[i];
        }

        v[12] ^= t0;
        v[13] ^= t1;
        if (f) v[14] = ~v[14];

        var round: u32 = 0;
        while (round < rounds) : (round += 1) {
            const s = BLAKE2B_SIGMA[round % 10];
            blake2bG(&v, 0, 4, 8, 12, m[s[0]], m[s[1]]);
            blake2bG(&v, 1, 5, 9, 13, m[s[2]], m[s[3]]);
            blake2bG(&v, 2, 6, 10, 14, m[s[4]], m[s[5]]);
            blake2bG(&v, 3, 7, 11, 15, m[s[6]], m[s[7]]);
            blake2bG(&v, 0, 5, 10, 15, m[s[8]], m[s[9]]);
            blake2bG(&v, 1, 6, 11, 12, m[s[10]], m[s[11]]);
            blake2bG(&v, 2, 7, 8, 13, m[s[12]], m[s[13]]);
            blake2bG(&v, 3, 4, 9, 14, m[s[14]], m[s[15]]);
        }

        i = 0;
        while (i < 8) : (i += 1) {
            h[i] ^= v[i] ^ v[i + 8];
        }
    }

    fn runBlake2FPrecompile(self: *EVM, input: []const u8, required_gas: u64) !PrecompileResult {
        if (input.len != 213) {
            return PrecompileResult{
                .success = false,
                .gas_used = required_gas,
                .output = try self.allocator.alloc(u8, 0),
            };
        }
        const final_flag = input[212];
        if (final_flag != 0 and final_flag != 1) {
            return PrecompileResult{
                .success = false,
                .gas_used = required_gas,
                .output = try self.allocator.alloc(u8, 0),
            };
        }

        const rounds = std.mem.readInt(u32, input[0..4], .big);
        var h: [8]u64 = undefined;
        var m: [16]u64 = undefined;
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            const start = 4 + i * 8;
            const chunk: *const [8]u8 = @ptrCast(input[start..][0..8].ptr);
            h[i] = std.mem.readInt(u64, chunk, .little);
        }
        i = 0;
        while (i < 16) : (i += 1) {
            const start = 68 + i * 8;
            const chunk: *const [8]u8 = @ptrCast(input[start..][0..8].ptr);
            m[i] = std.mem.readInt(u64, chunk, .little);
        }
        const t0_chunk: *const [8]u8 = @ptrCast(input[196..][0..8].ptr);
        const t1_chunk: *const [8]u8 = @ptrCast(input[204..][0..8].ptr);
        const t0 = std.mem.readInt(u64, t0_chunk, .little);
        const t1 = std.mem.readInt(u64, t1_chunk, .little);

        blake2bCompress(rounds, &h, m, t0, t1, final_flag == 1);

        const out = try self.allocator.alloc(u8, 64);
        i = 0;
        while (i < 8) : (i += 1) {
            const start = i * 8;
            const dst: *[8]u8 = @ptrCast(out[start..][0..8].ptr);
            std.mem.writeInt(u64, dst, h[i], .little);
        }
        return PrecompileResult{ .success = true, .gas_used = required_gas, .output = out };
    }

    fn readWordLen(input: []const u8, offset: usize) u64 {
        const readTailAsU64 = struct {
            fn run(bytes: []const u8) u64 {
                var v: u64 = 0;
                for (bytes) |b| {
                    v = (v << 8) | b;
                }
                return v;
            }
        }.run;

        if (offset + 32 <= input.len) {
            for (input[offset .. offset + 24]) |b| {
                if (b != 0) return std.math.maxInt(u64);
            }
            return readTailAsU64(input[offset + 24 .. offset + 32]);
        }

        var word = [_]u8{0} ** 32;
        if (offset < input.len) {
            const copy_len = @min(32, input.len - offset);
            @memcpy(word[0..copy_len], input[offset .. offset + copy_len]);
        }
        for (word[0..24]) |b| {
            if (b != 0) return std.math.maxInt(u64);
        }
        return readTailAsU64(word[24..32]);
    }

    fn readInputSegmentPadded(
        allocator: std.mem.Allocator,
        input: []const u8,
        data_offset: u64,
        segment_offset: u64,
        segment_len: u64,
    ) ![]u8 {
        const len: usize = @intCast(segment_len);
        const out = try allocator.alloc(u8, len);
        @memset(out, 0);
        if (len == 0) return out;

        const start_u64 = data_offset +| segment_offset;
        if (start_u64 >= input.len) return out;
        const start: usize = @intCast(start_u64);
        const available = input.len - start;
        const copy_len = @min(len, available);
        if (copy_len > 0) {
            @memcpy(out[0..copy_len], input[start .. start + copy_len]);
        }
        return out;
    }

    fn bitLenBE(bytes: []const u8) u64 {
        for (bytes, 0..) |b, i| {
            if (b != 0) {
                const bits_in_byte: u64 = 8 - @as(u64, @intCast(@clz(b)));
                return @as(u64, @intCast((bytes.len - i - 1) * 8)) + bits_in_byte;
            }
        }
        return 0;
    }

    fn modexpRequiredGas(input: []const u8) !u64 {
        const base_len = readWordLen(input, 0);
        const exp_len = readWordLen(input, 32);
        const mod_len = readWordLen(input, 64);

        const data_offset: u64 = 96;
        const exp_head_len_u64 = @min(exp_len, 32);
        const exp_head = try readInputSegmentPadded(std.heap.page_allocator, input, data_offset, base_len, exp_head_len_u64);
        defer std.heap.page_allocator.free(exp_head);

        const exp_head_bits = bitLenBE(exp_head);
        const iter_raw: u128 = if (exp_len == 0)
            0
        else if (exp_len <= 32)
            if (exp_head_bits == 0) 0 else exp_head_bits - 1
        else
            @as(u128, 8) * (exp_len - 32) + if (exp_head_bits == 0) 0 else exp_head_bits - 1;

        const iteration_count: u128 = @max(iter_raw, 1);
        const max_len = @max(base_len, mod_len);
        const words: u128 = (@as(u128, max_len) + 7) / 8;
        const mult_complexity: u128 = words * words;
        const computed: u128 = (mult_complexity * iteration_count) / 3;
        const final_gas: u128 = @max(@as(u128, 200), computed);
        return if (final_gas > std.math.maxInt(u64)) std.math.maxInt(u64) else @intCast(final_gas);
    }

    fn hexEncode(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
        const lut = "0123456789abcdef";
        const out = try allocator.alloc(u8, bytes.len * 2);
        for (bytes, 0..) |b, i| {
            out[i * 2] = lut[(b >> 4) & 0x0f];
            out[i * 2 + 1] = lut[b & 0x0f];
        }
        return out;
    }

    fn hexNibble(c: u8) !u8 {
        return switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => error.InvalidHex,
        };
    }

    fn managedFromBigEndian(allocator: std.mem.Allocator, bytes: []const u8) !std.math.big.int.Managed {
        var value = try std.math.big.int.Managed.init(allocator);
        errdefer value.deinit();
        if (bytes.len == 0) {
            try value.set(0);
            return value;
        }
        const hex = try hexEncode(allocator, bytes);
        defer allocator.free(hex);
        try value.setString(16, hex);
        return value;
    }

    fn managedToFixedLenBigEndian(allocator: std.mem.Allocator, value: std.math.big.int.Managed, out_len: usize) ![]u8 {
        const out = try allocator.alloc(u8, out_len);
        @memset(out, 0);
        if (out_len == 0) return out;

        const hex = try value.toString(allocator, 16, .lower);
        defer allocator.free(hex);
        if (hex.len == 0 or (hex.len == 1 and hex[0] == '0')) return out;

        var src_idx: usize = hex.len;
        var dst_idx: usize = out_len;
        while (src_idx > 0 and dst_idx > 0) {
            const lo = try hexNibble(hex[src_idx - 1]);
            src_idx -= 1;
            const hi: u8 = if (src_idx > 0) blk: {
                const h = try hexNibble(hex[src_idx - 1]);
                src_idx -= 1;
                break :blk h;
            } else 0;
            dst_idx -= 1;
            out[dst_idx] = (hi << 4) | lo;
        }
        return out;
    }

    fn runModExpPrecompile(self: *EVM, input: []const u8, required_gas: u64) !PrecompileResult {
        const base_len = readWordLen(input, 0);
        const exp_len = readWordLen(input, 32);
        const mod_len = readWordLen(input, 64);
        const data_offset: u64 = 96;

        const output_len: usize = @intCast(mod_len);
        if (mod_len == 0) {
            return PrecompileResult{
                .success = true,
                .gas_used = required_gas,
                .output = try self.allocator.alloc(u8, 0),
            };
        }

        const base_bytes = try readInputSegmentPadded(self.allocator, input, data_offset, 0, base_len);
        defer self.allocator.free(base_bytes);
        const exp_bytes = try readInputSegmentPadded(self.allocator, input, data_offset, base_len, exp_len);
        defer self.allocator.free(exp_bytes);
        const mod_bytes = try readInputSegmentPadded(self.allocator, input, data_offset, base_len +| exp_len, mod_len);
        defer self.allocator.free(mod_bytes);

        var base = try managedFromBigEndian(self.allocator, base_bytes);
        defer base.deinit();
        var exponent = try managedFromBigEndian(self.allocator, exp_bytes);
        defer exponent.deinit();
        var modulus = try managedFromBigEndian(self.allocator, mod_bytes);
        defer modulus.deinit();

        if (modulus.eqlZero()) {
            const out = try self.allocator.alloc(u8, output_len);
            @memset(out, 0);
            return PrecompileResult{
                .success = true,
                .gas_used = required_gas,
                .output = out,
            };
        }

        var quotient = try std.math.big.int.Managed.init(self.allocator);
        defer quotient.deinit();
        var rem = try std.math.big.int.Managed.init(self.allocator);
        defer rem.deinit();

        try std.math.big.int.Managed.divTrunc(&quotient, &rem, &base, &modulus);
        var base_mod = rem;
        var result = try std.math.big.int.Managed.initSet(self.allocator, 1);
        defer result.deinit();

        while (!exponent.eqlZero()) {
            if (exponent.isOdd()) {
                var prod = try std.math.big.int.Managed.init(self.allocator);
                defer prod.deinit();
                try std.math.big.int.Managed.mul(&prod, &result, &base_mod);
                try std.math.big.int.Managed.divTrunc(&quotient, &rem, &prod, &modulus);
                try result.copy(rem.toConst());
            }

            var squared = try std.math.big.int.Managed.init(self.allocator);
            defer squared.deinit();
            try std.math.big.int.Managed.mul(&squared, &base_mod, &base_mod);
            try std.math.big.int.Managed.divTrunc(&quotient, &rem, &squared, &modulus);
            try base_mod.copy(rem.toConst());

            var shifted = try std.math.big.int.Managed.init(self.allocator);
            defer shifted.deinit();
            try std.math.big.int.Managed.shiftRight(&shifted, &exponent, 1);
            try exponent.copy(shifted.toConst());
        }

        const out = try managedToFixedLenBigEndian(self.allocator, result, output_len);
        return PrecompileResult{
            .success = true,
            .gas_used = required_gas,
            .output = out,
        };
    }

    fn runPrecompile(self: *EVM, id: u8, input: []const u8, forwarded_gas: u64) !PrecompileResult {
        const words = (input.len + 31) / 32;
        const required_gas: u64 = switch (id) {
            1 => 3000, // ECRECOVER
            2 => 60 + 12 * words, // SHA256
            3 => 600 + 120 * words, // RIPEMD160
            4 => 15 + 3 * words, // IDENTITY
            5 => try modexpRequiredGas(input), // MODEXP (EIP-2565)
            6 => 150, // BN256ADD
            7 => 6000, // BN256MUL
            8 => blk: { // BN256PAIRING
                if (input.len % 192 != 0) break :blk std.math.maxInt(u64);
                const pairs = input.len / 192;
                break :blk 45_000 + 34_000 * pairs;
            },
            9 => blk: { // BLAKE2F
                if (input.len < 4) break :blk std.math.maxInt(u64);
                break :blk std.mem.readInt(u32, input[0..4], .big);
            },
            else => forwarded_gas,
        };

        if (required_gas > forwarded_gas) {
            return PrecompileResult{
                .success = false,
                .gas_used = forwarded_gas,
                .output = try self.allocator.alloc(u8, 0),
            };
        }

        switch (id) {
            1 => {
                var in_buf = [_]u8{0} ** 128;
                const in_len = @min(input.len, in_buf.len);
                @memcpy(in_buf[0..in_len], input[0..in_len]);

                const msg_hash = in_buf[0..32].*;
                const v_word = in_buf[32..64];
                const v = v_word[31];
                const r = in_buf[64..96].*;
                const s = in_buf[96..128].*;

                if (crypto.ecrecoverAddress(msg_hash, v, r, s)) |addr| {
                    const out = try self.allocator.alloc(u8, 32);
                    @memset(out, 0);
                    @memcpy(out[12..32], addr[0..20]);
                    return PrecompileResult{ .success = true, .gas_used = required_gas, .output = out };
                }
                return PrecompileResult{
                    .success = true,
                    .gas_used = required_gas,
                    .output = try self.allocator.alloc(u8, 0),
                };
            },
            2 => {
                const out = try self.allocator.alloc(u8, 32);
                std.crypto.hash.sha2.Sha256.hash(input, out[0..32], .{});
                return PrecompileResult{ .success = true, .gas_used = required_gas, .output = out };
            },
            3 => {
                const out = try self.allocator.alloc(u8, 32);
                @memset(out, 0);
                var h: [20]u8 = undefined;
                crypto.ripemd160(input, &h);
                @memcpy(out[12..32], h[0..20]);
                return PrecompileResult{ .success = true, .gas_used = required_gas, .output = out };
            },
            4 => {
                const out = try self.allocator.alloc(u8, input.len);
                if (input.len > 0) @memcpy(out, input);
                return PrecompileResult{ .success = true, .gas_used = required_gas, .output = out };
            },
            5 => return try self.runModExpPrecompile(input, required_gas),
            6 => return try self.runBn256AddPrecompile(input, required_gas),
            7 => return try self.runBn256MulPrecompile(input, required_gas),
            8 => return try self.runBn256PairingPrecompile(input, required_gas),
            9 => return try self.runBlake2FPrecompile(input, required_gas),
            else => {
                return PrecompileResult{
                    .success = false,
                    .gas_used = required_gas,
                    .output = try self.allocator.alloc(u8, 0),
                };
            },
        }
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

    pub fn execute(self: *EVM, code: []const u8, data: []const u8) !ExecutionResult {
        self.context.code = code;
        self.context.calldata = data;
        self.halted = false;
        self.clearReturnData();
        var tx_snapshot: ?usize = null;
        var tx_committed = false;
        if (self.state_db) |db| {
            tx_snapshot = try db.snapshot();
        }
        defer {
            if (self.state_db) |db| {
                if (tx_snapshot) |sid| {
                    if (!tx_committed) {
                        db.revertToSnapshot(sid) catch {};
                    }
                }
            }
        }
        var pc: usize = 0;

        while (pc < code.len) {
            if (self.halted) break;
            if (self.gas_used >= self.gas_limit) {
                return error.OutOfGas;
            }

            const opcode = @as(Opcode, @enumFromInt(code[pc]));
            pc += 1;

            self.executeOpcode(opcode, code, &pc) catch |err| {
                if (err == error.Revert) {
                    return ExecutionResult{
                        .success = false,
                        .gas_used = self.gas_used,
                        .gas_refund = self.gas_refund,
                        .return_data = if (self.return_data.len == 0) &[_]u8{} else try self.allocator.dupe(u8, self.return_data),
                        .logs = &[_]Log{},
                    };
                }
                return err;
            };
        }

        if (self.state_db) |db| {
            if (tx_snapshot) |sid| {
                try db.commitSnapshot(sid);
                tx_committed = true;
            }
        }
        return ExecutionResult{
            .success = true,
            .gas_used = self.gas_used,
            .gas_refund = self.gas_refund,
            .return_data = if (self.return_data.len == 0) &[_]u8{} else try self.allocator.dupe(u8, self.return_data),
            .logs = try self.logs.toOwnedSlice(),
        };
    }

    fn executeOpcode(self: *EVM, opcode: Opcode, code: []const u8, pc: *usize) !void {
        switch (opcode) {
            .STOP => {
                self.halted = true;
                return;
            },

            // Arithmetic
            .ADD => try self.opAdd(),
            .MUL => try self.opMul(),
            .SUB => try self.opSub(),
            .DIV => try self.opDiv(),
            .SDIV => try self.opSdiv(),
            .MOD => try self.opMod(),
            .SMOD => try self.opSmod(),
            .ADDMOD => try self.opAddmod(),
            .MULMOD => try self.opMulmod(),
            .EXP => try self.opExp(),
            .SIGNEXTEND => try self.opSignExtend(),

            // Comparison
            .LT => try self.opLt(),
            .GT => try self.opGt(),
            .SLT => try self.opSlt(),
            .SGT => try self.opSgt(),
            .EQ => try self.opEq(),
            .ISZERO => try self.opIsZero(),

            // Bitwise
            .AND => try self.opAnd(),
            .OR => try self.opOr(),
            .XOR => try self.opXor(),
            .NOT => try self.opNot(),
            .BYTE => try self.opByte(),
            .SHL => try self.opShl(),
            .SHR => try self.opShr(),
            .SAR => try self.opSar(),

            // Stack operations
            .POP => try self.opPop(),
            .PUSH1 => try self.opPush(code, pc, 1),
            .PUSH2 => try self.opPush(code, pc, 2),
            .PUSH3 => try self.opPush(code, pc, 3),
            .PUSH4 => try self.opPush(code, pc, 4),
            .PUSH5 => try self.opPush(code, pc, 5),
            .PUSH6 => try self.opPush(code, pc, 6),
            .PUSH7 => try self.opPush(code, pc, 7),
            .PUSH8 => try self.opPush(code, pc, 8),
            .PUSH9 => try self.opPush(code, pc, 9),
            .PUSH10 => try self.opPush(code, pc, 10),
            .PUSH11 => try self.opPush(code, pc, 11),
            .PUSH12 => try self.opPush(code, pc, 12),
            .PUSH13 => try self.opPush(code, pc, 13),
            .PUSH14 => try self.opPush(code, pc, 14),
            .PUSH15 => try self.opPush(code, pc, 15),
            .PUSH16 => try self.opPush(code, pc, 16),
            .PUSH17 => try self.opPush(code, pc, 17),
            .PUSH18 => try self.opPush(code, pc, 18),
            .PUSH19 => try self.opPush(code, pc, 19),
            .PUSH20 => try self.opPush(code, pc, 20),
            .PUSH21 => try self.opPush(code, pc, 21),
            .PUSH22 => try self.opPush(code, pc, 22),
            .PUSH23 => try self.opPush(code, pc, 23),
            .PUSH24 => try self.opPush(code, pc, 24),
            .PUSH25 => try self.opPush(code, pc, 25),
            .PUSH26 => try self.opPush(code, pc, 26),
            .PUSH27 => try self.opPush(code, pc, 27),
            .PUSH28 => try self.opPush(code, pc, 28),
            .PUSH29 => try self.opPush(code, pc, 29),
            .PUSH30 => try self.opPush(code, pc, 30),
            .PUSH31 => try self.opPush(code, pc, 31),
            .PUSH32 => try self.opPush(code, pc, 32),

            // Duplication
            .DUP1 => try self.opDup(1),
            .DUP2 => try self.opDup(2),
            .DUP3 => try self.opDup(3),
            .DUP4 => try self.opDup(4),
            .DUP5 => try self.opDup(5),
            .DUP6 => try self.opDup(6),
            .DUP7 => try self.opDup(7),
            .DUP8 => try self.opDup(8),
            .DUP9 => try self.opDup(9),
            .DUP10 => try self.opDup(10),
            .DUP11 => try self.opDup(11),
            .DUP12 => try self.opDup(12),
            .DUP13 => try self.opDup(13),
            .DUP14 => try self.opDup(14),
            .DUP15 => try self.opDup(15),
            .DUP16 => try self.opDup(16),

            // Swap
            .SWAP1 => try self.opSwap(1),
            .SWAP2 => try self.opSwap(2),
            .SWAP3 => try self.opSwap(3),
            .SWAP4 => try self.opSwap(4),
            .SWAP5 => try self.opSwap(5),
            .SWAP6 => try self.opSwap(6),
            .SWAP7 => try self.opSwap(7),
            .SWAP8 => try self.opSwap(8),
            .SWAP9 => try self.opSwap(9),
            .SWAP10 => try self.opSwap(10),
            .SWAP11 => try self.opSwap(11),
            .SWAP12 => try self.opSwap(12),
            .SWAP13 => try self.opSwap(13),
            .SWAP14 => try self.opSwap(14),
            .SWAP15 => try self.opSwap(15),
            .SWAP16 => try self.opSwap(16),

            // Memory
            .MLOAD => try self.opMload(),
            .MSTORE => try self.opMstore(),
            .MSTORE8 => try self.opMstore8(),
            .MSIZE => try self.opMsize(),

            // Storage
            .SLOAD => try self.opSload(),
            .SSTORE => try self.opSstore(),

            // Flow control
            .JUMP => try self.opJump(pc),
            .JUMPI => try self.opJumpi(pc),
            .JUMPDEST => self.gas_used += 1,
            .PC => try self.opPc(pc),
            .GAS => try self.opGas(),

            // Environmental
            .ADDRESS => try self.opAddress(),
            .CALLER => try self.opCaller(),
            .ORIGIN => try self.opOrigin(),
            .CALLVALUE => try self.opCallValue(),
            .CALLDATALOAD => try self.opCallDataLoad(),
            .CALLDATASIZE => try self.opCallDataSize(),
            .CALLDATACOPY => try self.opCallDataCopy(),
            .CODESIZE => try self.opCodeSize(),
            .CODECOPY => try self.opCodeCopy(),
            .GASPRICE => try self.opGasPrice(),
            .BALANCE => try self.opBalance(),
            .EXTCODESIZE => try self.opExtCodeSize(),
            .EXTCODECOPY => try self.opExtCodeCopy(),
            .EXTCODEHASH => try self.opExtCodeHash(),

            // Block information
            .BLOCKHASH => try self.opBlockhash(),
            .COINBASE => try self.opCoinbase(),
            .TIMESTAMP => try self.opTimestamp(),
            .NUMBER => try self.opNumber(),
            .DIFFICULTY => try self.opDifficulty(),
            .GASLIMIT => try self.opGasLimit(),
            .CHAINID => try self.opChainId(),
            .BASEFEE => try self.opBaseFee(),
            .SELFBALANCE => try self.opSelfBalance(),

            // Hashing
            .SHA3 => try self.opSha3(),

            // Logging
            .LOG0 => try self.opLog(0),
            .LOG1 => try self.opLog(1),
            .LOG2 => try self.opLog(2),
            .LOG3 => try self.opLog(3),
            .LOG4 => try self.opLog(4),

            // Return data operations
            .RETURNDATASIZE => try self.opReturnDataSize(),
            .RETURNDATACOPY => try self.opReturnDataCopy(),

            // System
            .RETURN => try self.opReturn(),
            .REVERT => try self.opRevert(),
            .CALL => try self.opCall(),
            .CALLCODE => try self.opCallCode(),
            .STATICCALL => try self.opStaticCall(),
            .DELEGATECALL => try self.opDelegateCall(),
            .CREATE => try self.opCreate(),
            .CREATE2 => try self.opCreate2(),
            .SELFDESTRUCT => try self.opSelfDestruct(),

            else => return error.InvalidOpcode,
        }
    }

    fn opAdd(self: *EVM) !void {
        const a = try self.stack.pop();
        const b = try self.stack.pop();
        try self.stack.push(self.allocator, a.add(b));
        self.gas_used += 3;
    }

    fn opMul(self: *EVM) !void {
        const a = try self.stack.pop();
        const b = try self.stack.pop();
        try self.stack.push(self.allocator, a.mul(b));
        self.gas_used += 5;
    }

    fn opSub(self: *EVM) !void {
        const a = try self.stack.pop(); // top of stack
        const b = try self.stack.pop(); // second
        try self.stack.push(self.allocator, b.sub(a)); // b - a (reversed!)
        self.gas_used += 3;
    }

    fn opDiv(self: *EVM) !void {
        const a = try self.stack.pop(); // top
        const b = try self.stack.pop(); // second
        try self.stack.push(self.allocator, b.div(a)); // b / a (reversed!)
        self.gas_used += 5;
    }

    fn opMod(self: *EVM) !void {
        const a = try self.stack.pop(); // top
        const b = try self.stack.pop(); // second
        try self.stack.push(self.allocator, b.mod(a)); // b % a (reversed!)
        self.gas_used += 5;
    }

    fn opAddmod(self: *EVM) !void {
        // ADDMOD: (a + b) % m
        // Stack: a, b, m -> result
        const m = try self.stack.pop();
        const b = try self.stack.pop();
        const a = try self.stack.pop();

        // Handle modulo by zero
        if (m.isZero()) {
            try self.stack.push(self.allocator, types.U256.zero());
            self.gas_used += 8;
            return;
        }

        // Calculate (a + b) mod m
        const sum = a.add(b);
        const result = sum.mod(m);

        try self.stack.push(self.allocator, result);
        self.gas_used += 8;
    }

    fn opMulmod(self: *EVM) !void {
        // MULMOD: (a * b) % m
        // Stack: a, b, m -> result
        const m = try self.stack.pop();
        const b = try self.stack.pop();
        const a = try self.stack.pop();

        // Handle modulo by zero
        if (m.isZero()) {
            try self.stack.push(self.allocator, types.U256.zero());
            self.gas_used += 8;
            return;
        }

        // Calculate (a * b) mod m
        const product = a.mul(b);
        const result = product.mod(m);

        try self.stack.push(self.allocator, result);
        self.gas_used += 8;
    }

    fn opSdiv(self: *EVM) !void {
        // Signed division: result = sign(b/a) * abs(b/a)
        // EVM uses two's complement representation
        const a = try self.stack.pop();
        const b = try self.stack.pop();

        // Handle division by zero
        if (a.isZero()) {
            try self.stack.push(self.allocator, types.U256.zero());
            self.gas_used += 5;
            return;
        }

        // Check signs
        const a_negative = types.U256.isSignedNegative(a);
        const b_negative = types.U256.isSignedNegative(b);

        // Get absolute values
        const a_abs = a.signedAbs();
        const b_abs = b.signedAbs();

        // Perform unsigned division
        const abs_result = b_abs.div(a_abs);

        // Determine sign: negative if signs differ
        const result_negative = (a_negative != b_negative);

        // Apply sign if needed
        const result = if (result_negative and !abs_result.isZero())
            abs_result.signedNegateFast()
        else
            abs_result;

        try self.stack.push(self.allocator, result);
        self.gas_used += 5;
    }

    fn opSmod(self: *EVM) !void {
        // Signed modulo: result = sign(b) * abs(b) % abs(a)
        // EVM uses two's complement representation
        const a = try self.stack.pop();
        const b = try self.stack.pop();

        // Handle modulo by zero
        if (a.isZero()) {
            try self.stack.push(self.allocator, types.U256.zero());
            self.gas_used += 5;
            return;
        }

        // Check if b is negative (sign of result)
        const b_negative = types.U256.isSignedNegative(b);

        // Get absolute values
        const a_abs = a.signedAbs();
        const b_abs = b.signedAbs();

        // Perform unsigned modulo
        const abs_result = b_abs.mod(a_abs);

        // Apply sign of b if result is non-zero
        const result = if (b_negative and !abs_result.isZero())
            abs_result.signedNegateFast()
        else
            abs_result;

        try self.stack.push(self.allocator, result);
        self.gas_used += 5;
    }

    fn opSignExtend(self: *EVM) !void {
        // SIGNEXTEND(i, x): Extend sign of (i*8+7)th bit of x to all higher bits
        const bit_pos_u256 = try self.stack.pop();
        const value = try self.stack.pop();

        const bit_pos = @as(u6, @intCast(bit_pos_u256.limbs[0] & 31)); // 0-31 bytes
        const bit_index = bit_pos * 8 + 7; // Which bit to check (0-255)

        if (bit_index >= 256) {
            // No extension needed
            try self.stack.push(self.allocator, value);
            self.gas_used += 5;
            return;
        }

        // Check the sign bit
        const byte_idx = bit_index / 8;
        const bit_in_byte = bit_index % 8;
        const sign_bit = (value.limbs[byte_idx / 4] >> @as(u6, @intCast((byte_idx % 4) * 8 + bit_in_byte))) & 1;

        // If sign bit is 1, extend with 0xFF, else with 0x00
        var result = value;
        if (sign_bit == 1) {
            // Set all bits above bit_index to 1
            const mask_start_byte = (bit_index / 8) + 1;

            // Build mask for extension (U256 has 4 limbs of u64)
            var mask = types.U256.zero();
            var i: usize = mask_start_byte;
            while (i < 32) : (i += 1) {
                const limb_idx = i / 8; // 8 bytes per limb
                const byte_in_limb = i % 8;
                if (limb_idx < 4) {
                    mask.limbs[limb_idx] |= @as(u64, 0xFF) << @as(u6, @intCast(byte_in_limb * 8));
                }
            }

            // Apply mask
            result.limbs[0] |= mask.limbs[0];
            result.limbs[1] |= mask.limbs[1];
            result.limbs[2] |= mask.limbs[2];
            result.limbs[3] |= mask.limbs[3];
        }

        try self.stack.push(self.allocator, result);
        self.gas_used += 5;
    }

    fn opExp(self: *EVM) !void {
        const exponent = try self.stack.pop();
        const base = try self.stack.pop();

        var result = types.U256.one();
        var current_base = base;
        var remaining_exp = exponent;

        while (!remaining_exp.isZero()) {
            if ((remaining_exp.limbs[0] & 1) != 0) {
                result = result.mul(current_base);
            }
            current_base = current_base.mul(current_base);
            remaining_exp = u256Shr(remaining_exp, 1);
        }

        try self.stack.push(self.allocator, result);

        // Gas cost: 10 + 50 * (number of bytes to represent exponent)
        // Count bytes from LSB (right to left), stopping at first non-zero
        // This gives us the minimum bytes needed to represent the value
        const exp_bytes_array = exponent.toBytes();
        var exp_bytes: u64 = 1; // At least 1 byte
        var found_significant = false;
        var i: usize = exp_bytes_array.len;
        while (i > 0) {
            i -= 1;
            if (exp_bytes_array[i] != 0) {
                found_significant = true;
                exp_bytes = @as(u64, exp_bytes_array.len - i);
                break;
            }
        }
        if (!found_significant) {
            exp_bytes = 1; // Zero exponent = 1 byte
        }

        self.gas_used += 10 + 50 * exp_bytes;
    }

    // Comparison opcodes
    fn opLt(self: *EVM) !void {
        const a = try self.stack.pop(); // top
        const b = try self.stack.pop(); // second
        const result = if (b.lt(a)) types.U256.one() else types.U256.zero(); // b < a
        try self.stack.push(self.allocator, result);
        self.gas_used += 3;
    }

    fn opGt(self: *EVM) !void {
        const a = try self.stack.pop(); // top
        const b = try self.stack.pop(); // second
        const result = if (b.gt(a)) types.U256.one() else types.U256.zero(); // b > a
        try self.stack.push(self.allocator, result);
        self.gas_used += 3;
    }

    fn opEq(self: *EVM) !void {
        const a = try self.stack.pop();
        const b = try self.stack.pop();
        const result = if (a.eq(b)) types.U256.one() else types.U256.zero();
        try self.stack.push(self.allocator, result);
        self.gas_used += 3;
    }

    fn opSlt(self: *EVM) !void {
        // Signed less than
        const a = try self.stack.pop();
        const b = try self.stack.pop();

        // Check if negative (MSB is set)
        const a_is_neg = (a.limbs[3] & 0x8000000000000000) != 0;
        const b_is_neg = (b.limbs[3] & 0x8000000000000000) != 0;

        var result: bool = false;
        if (b_is_neg != a_is_neg) {
            // Different signs: negative < positive
            result = b_is_neg;
        } else {
            // Same sign: compare as unsigned
            result = b.lt(a);
        }

        try self.stack.push(self.allocator, if (result) types.U256.one() else types.U256.zero());
        self.gas_used += 3;
    }

    fn opSgt(self: *EVM) !void {
        // Signed greater than (opposite of SLT)
        const a = try self.stack.pop();
        const b = try self.stack.pop();

        // Check if negative (MSB is set)
        const a_is_neg = (a.limbs[3] & 0x8000000000000000) != 0;
        const b_is_neg = (b.limbs[3] & 0x8000000000000000) != 0;

        var result: bool = false;
        if (b_is_neg != a_is_neg) {
            // Different signs: positive > negative
            result = !b_is_neg;
        } else {
            // Same sign: compare as unsigned
            result = b.gt(a);
        }

        try self.stack.push(self.allocator, if (result) types.U256.one() else types.U256.zero());
        self.gas_used += 3;
    }

    fn opIsZero(self: *EVM) !void {
        const a = try self.stack.pop();
        const result = if (a.isZero()) types.U256.one() else types.U256.zero();
        try self.stack.push(self.allocator, result);
        self.gas_used += 3;
    }

    // Bitwise opcodes
    fn opAnd(self: *EVM) !void {
        const a = try self.stack.pop();
        const b = try self.stack.pop();
        var result = types.U256.zero();
        for (0..4) |i| {
            result.limbs[i] = a.limbs[i] & b.limbs[i];
        }
        try self.stack.push(self.allocator, result);
        self.gas_used += 3;
    }

    fn opOr(self: *EVM) !void {
        const a = try self.stack.pop();
        const b = try self.stack.pop();
        var result = types.U256.zero();
        for (0..4) |i| {
            result.limbs[i] = a.limbs[i] | b.limbs[i];
        }
        try self.stack.push(self.allocator, result);
        self.gas_used += 3;
    }

    fn opXor(self: *EVM) !void {
        const a = try self.stack.pop();
        const b = try self.stack.pop();
        var result = types.U256.zero();
        for (0..4) |i| {
            result.limbs[i] = a.limbs[i] ^ b.limbs[i];
        }
        try self.stack.push(self.allocator, result);
        self.gas_used += 3;
    }

    fn opNot(self: *EVM) !void {
        const a = try self.stack.pop();
        var result = types.U256.zero();
        for (0..4) |i| {
            result.limbs[i] = ~a.limbs[i];
        }
        try self.stack.push(self.allocator, result);
        self.gas_used += 3;
    }

    fn opByte(self: *EVM) !void {
        // BYTE(i, x): ith byte of x, where i=0 is MSB and i=31 is LSB
        const i_u256 = try self.stack.pop();
        const x = try self.stack.pop();

        const i = i_u256.limbs[0];
        if (i >= 32) {
            // Index out of range, return 0
            try self.stack.push(self.allocator, types.U256.zero());
            self.gas_used += 3;
            return;
        }

        // Extract byte (i=0 is MSB, i=31 is LSB)
        const byte_idx = 31 - @as(u6, @intCast(i)); // Reverse: 0=LSB, 31=MSB in our representation
        const limb_idx = byte_idx / 8;
        const byte_in_limb = byte_idx % 8;
        const byte_val = @as(u8, @truncate((x.limbs[limb_idx] >> @as(u6, @intCast(byte_in_limb * 8))) & 0xFF));

        var result = types.U256.zero();
        result.limbs[0] = byte_val;
        try self.stack.push(self.allocator, result);
        self.gas_used += 3;
    }

    fn opShl(self: *EVM) !void {
        const shift_u256 = try self.stack.pop();
        const value = try self.stack.pop();
        const shift = shift_u256.limbs[0];
        const result = u256Shl(value, shift);
        try self.stack.push(self.allocator, result);
        self.gas_used += 3;
    }

    fn opShr(self: *EVM) !void {
        const shift_u256 = try self.stack.pop();
        const value = try self.stack.pop();
        const shift = shift_u256.limbs[0];
        const result = u256Shr(value, shift);
        try self.stack.push(self.allocator, result);
        self.gas_used += 3;
    }

    fn opSar(self: *EVM) !void {
        // SAR (Signed Arithmetic Right Shift): preserves sign bit
        const shift_u256 = try self.stack.pop();
        const value = try self.stack.pop();

        const shift = shift_u256.limbs[0];
        const result = u256Sar(value, shift);
        try self.stack.push(self.allocator, result);
        self.gas_used += 3;
    }

    // Duplication opcodes
    fn opDup(self: *EVM, n: usize) !void {
        if (self.stack.items.items.len < n) {
            return error.StackUnderflow;
        }
        const idx = self.stack.items.items.len - n;
        const value = self.stack.items.items[idx];
        try self.stack.push(self.allocator, value);
        self.gas_used += 3;
    }

    // Swap opcodes
    fn opSwap(self: *EVM, n: usize) !void {
        if (self.stack.items.items.len < n + 1) {
            return error.StackUnderflow;
        }
        const len = self.stack.items.items.len;
        const temp = self.stack.items.items[len - 1];
        self.stack.items.items[len - 1] = self.stack.items.items[len - 1 - n];
        self.stack.items.items[len - 1 - n] = temp;
        self.gas_used += 3;
    }

    // Additional memory/flow opcodes
    fn opMsize(self: *EVM) !void {
        const size = types.U256.fromU64(self.memory.data.items.len);
        try self.stack.push(self.allocator, size);
        self.gas_used += 2;
    }

    fn opPc(self: *EVM, pc: *usize) !void {
        // PC returns the position of the current instruction
        // Since pc is incremented before executeOpcode, we subtract 1
        const value = types.U256.fromU64(pc.* - 1);
        try self.stack.push(self.allocator, value);
        self.gas_used += 2;
    }

    fn opGas(self: *EVM) !void {
        const remaining = types.U256.fromU64(self.gas_limit - self.gas_used);
        try self.stack.push(self.allocator, remaining);
        self.gas_used += 2;
    }

    // Environmental opcodes
    fn opAddress(self: *EVM) !void {
        try self.stack.push(self.allocator, addressToU256(self.context.address));
        self.gas_used += 2;
    }

    fn opCaller(self: *EVM) !void {
        try self.stack.push(self.allocator, addressToU256(self.context.caller));
        self.gas_used += 2;
    }

    fn opOrigin(self: *EVM) !void {
        try self.stack.push(self.allocator, addressToU256(self.context.origin));
        self.gas_used += 2;
    }

    fn opCallValue(self: *EVM) !void {
        try self.stack.push(self.allocator, self.context.value);
        self.gas_used += 2;
    }

    fn opCallDataLoad(self: *EVM) !void {
        const offset_u256 = try self.stack.pop();
        const offset = offset_u256.limbs[0];

        var value = types.U256.zero();
        if (offset < self.context.calldata.len) {
            const end = @min(offset + 32, self.context.calldata.len);
            const copy_len = end - offset;
            var bytes = value.toBytes();
            @memcpy(bytes[0..copy_len], self.context.calldata[offset..end]);
            value = types.U256.fromBytes(bytes);
        }

        try self.stack.push(self.allocator, value);
        self.gas_used += 3;
    }

    fn opCallDataSize(self: *EVM) !void {
        const size = types.U256.fromU64(self.context.calldata.len);
        try self.stack.push(self.allocator, size);
        self.gas_used += 2;
    }

    fn opCallDataCopy(self: *EVM) !void {
        // Stack: memOffset, calldataOffset, length
        const mem_offset_u256 = try self.stack.pop();
        const calldata_offset_u256 = try self.stack.pop();
        const length_u256 = try self.stack.pop();

        const mem_offset = mem_offset_u256.limbs[0];
        const calldata_offset = calldata_offset_u256.limbs[0];
        const length = length_u256.limbs[0];

        // Calculate required memory size
        const new_size = if (length > 0 and mem_offset < 0xFFFFFFFFFFFFFFFF)
            @min(mem_offset + length, 0xFFFFFFFF)
        else
            mem_offset;

        // Expand memory if needed
        if (new_size > self.memory.data.items.len) {
            try self.memory.data.resize(new_size);
        }

        // Copy from calldata to memory
        if (length > 0 and calldata_offset < self.context.calldata.len) {
            const src_end = @min(calldata_offset + length, self.context.calldata.len);
            const copy_len = src_end - calldata_offset;

            // Copy actual data
            if (copy_len > 0) {
                @memcpy(self.memory.data.items[mem_offset..][0..copy_len], self.context.calldata[calldata_offset..src_end]);
            }

            // Zero out remaining bytes if length exceeds available calldata
            if (copy_len < length) {
                @memset(self.memory.data.items[mem_offset + copy_len ..][0 .. length - copy_len], 0);
            }
        } else if (length > 0) {
            // Calldata offset beyond available data - zero out memory
            @memset(self.memory.data.items[mem_offset..][0..length], 0);
        }

        // Gas cost: 3 base + memory expansion + copy cost
        const mem_cost = self.memoryExpansionCost(new_size);
        const copy_cost = (length + 31) / 32; // Words to copy (minimum 1)
        self.gas_used += 3 + mem_cost + copy_cost;
    }

    fn opCodeSize(self: *EVM) !void {
        const size = types.U256.fromU64(self.context.code.len);
        try self.stack.push(self.allocator, size);
        self.gas_used += 2;
    }

    fn opCodeCopy(self: *EVM) !void {
        // Stack: memOffset, codeOffset, length
        const mem_offset_u256 = try self.stack.pop();
        const code_offset_u256 = try self.stack.pop();
        const length_u256 = try self.stack.pop();

        const mem_offset = mem_offset_u256.limbs[0];
        const code_offset = code_offset_u256.limbs[0];
        const length = length_u256.limbs[0];

        // Calculate required memory size
        const new_size = if (length > 0 and mem_offset < 0xFFFFFFFFFFFFFFFF)
            @min(mem_offset + length, 0xFFFFFFFF)
        else
            mem_offset;

        // Expand memory if needed
        if (new_size > self.memory.data.items.len) {
            try self.memory.data.resize(new_size);
        }

        // Copy from code to memory
        if (length > 0 and code_offset < self.context.code.len) {
            const src_end = @min(code_offset + length, self.context.code.len);
            const copy_len = src_end - code_offset;

            // Copy actual data
            if (copy_len > 0) {
                @memcpy(self.memory.data.items[mem_offset..][0..copy_len], self.context.code[code_offset..src_end]);
            }

            // Zero out remaining bytes if length exceeds available code
            if (copy_len < length) {
                @memset(self.memory.data.items[mem_offset + copy_len ..][0 .. length - copy_len], 0);
            }
        } else if (length > 0) {
            // Code offset beyond available code - zero out memory
            @memset(self.memory.data.items[mem_offset..][0..length], 0);
        }

        // Gas cost: 3 base + memory expansion + copy cost
        const mem_cost = self.memoryExpansionCost(new_size);
        const copy_cost = (length + 31) / 32; // Words to copy (minimum 1)
        self.gas_used += 3 + mem_cost + copy_cost;
    }

    fn opGasPrice(self: *EVM) !void {
        // Fixed gas price for now
        const price = types.U256.fromU64(20000000000); // 20 gwei
        try self.stack.push(self.allocator, price);
        self.gas_used += 2;
    }

    fn opBalance(self: *EVM) !void {
        // BALANCE(address): Get balance of account at address
        const address_u256 = try self.stack.pop();
        const address = u256ToAddress(address_u256);

        // Look up balance from state if available
        if (self.state_db) |db| {
            const balance = db.getBalance(address) catch types.U256.zero();
            try self.stack.push(self.allocator, balance);
        } else {
            // No state database - return 0
            try self.stack.push(self.allocator, types.U256.zero());
        }

        self.gas_used += try self.accountAccessCost(address);
    }

    fn opExtCodeSize(self: *EVM) !void {
        // EXTCODESIZE(address): Get size of code at address
        const address_u256 = try self.stack.pop();
        const address = u256ToAddress(address_u256);

        // Look up code size from state if available
        if (self.state_db) |db| {
            const code = db.getCode(address);
            try self.stack.push(self.allocator, types.U256.fromU64(code.len));
        } else {
            // No state database - return 0
            try self.stack.push(self.allocator, types.U256.zero());
        }

        self.gas_used += try self.accountAccessCost(address);
    }

    fn opExtCodeCopy(self: *EVM) !void {
        // EXTCODECOPY(address, memOffset, codeOffset, length): Copy code from external account to memory
        const address_u256 = try self.stack.pop();
        const mem_offset_u256 = try self.stack.pop();
        const code_offset_u256 = try self.stack.pop();
        const length_u256 = try self.stack.pop();

        const address = u256ToAddress(address_u256);

        const code_offset = code_offset_u256.limbs[0];
        const mem_offset = mem_offset_u256.limbs[0];
        const length = length_u256.limbs[0];

        // Calculate required memory size
        const new_size = if (length > 0 and mem_offset < 0xFFFFFFFFFFFFFFFF)
            @min(mem_offset + length, 0xFFFFFFFF)
        else
            mem_offset;

        // Expand memory if needed
        if (new_size > self.memory.data.items.len) {
            try self.memory.data.resize(new_size);
        }

        if (length > 0) {
            @memset(self.memory.data.items[mem_offset..][0..length], 0);

            if (self.state_db) |db| {
                const code = db.getCode(address);
                if (code_offset < code.len) {
                    const src_end = @min(code_offset + length, code.len);
                    const copy_len = src_end - code_offset;
                    if (copy_len > 0) {
                        @memcpy(
                            self.memory.data.items[mem_offset..][0..copy_len],
                            code[code_offset..src_end],
                        );
                    }
                }
            }
        }

        // Gas cost: 20 base + account access (EIP-2929) + memory expansion + copy cost
        const mem_cost = self.memoryExpansionCost(new_size);
        const copy_cost = (length + 31) / 32; // Words to copy (minimum 1)
        self.gas_used += 20 + mem_cost + copy_cost + try self.accountAccessCost(address);
    }

    fn opExtCodeHash(self: *EVM) !void {
        // EXTCODEHASH(address): Get hash of code at address (EIP-1052)
        const address_u256 = try self.stack.pop();
        const address = u256ToAddress(address_u256);

        // Look up code hash from state if available
        if (self.state_db) |db| {
            if (!db.exists(address)) {
                try self.stack.push(self.allocator, types.U256.zero());
            } else {
                const code = db.getCode(address);
                var hash: [32]u8 = undefined;
                crypto.keccak256(code, &hash);
                try self.stack.push(self.allocator, types.U256.fromBytes(hash));
            }
        } else {
            // No state database - return 0
            try self.stack.push(self.allocator, types.U256.zero());
        }
        self.gas_used += try self.accountAccessCost(address);
    }

    // Block information opcodes
    fn opCoinbase(self: *EVM) !void {
        var value = types.U256.zero();
        for (self.context.block_coinbase.bytes, 0..) |byte, i| {
            if (i < 20) value.limbs[0] |= @as(u64, byte) << @intCast((19 - i) * 8);
        }
        try self.stack.push(self.allocator, value);
        self.gas_used += 2;
    }

    fn opTimestamp(self: *EVM) !void {
        const timestamp = types.U256.fromU64(self.context.block_timestamp);
        try self.stack.push(self.allocator, timestamp);
        self.gas_used += 2;
    }

    fn opNumber(self: *EVM) !void {
        const number = types.U256.fromU64(self.context.block_number);
        try self.stack.push(self.allocator, number);
        self.gas_used += 2;
    }

    fn opDifficulty(self: *EVM) !void {
        try self.stack.push(self.allocator, self.context.block_difficulty);
        self.gas_used += 2;
    }

    fn opGasLimit(self: *EVM) !void {
        const gaslimit = types.U256.fromU64(self.context.block_gaslimit);
        try self.stack.push(self.allocator, gaslimit);
        self.gas_used += 2;
    }

    fn opChainId(self: *EVM) !void {
        const chain_id = types.U256.fromU64(self.context.chain_id);
        try self.stack.push(self.allocator, chain_id);
        self.gas_used += 2;
    }

    fn opBlockhash(self: *EVM) !void {
        // BLOCKHASH: Hash of a given block
        // Stack: blockNumber -> hash
        const block_number_u256 = try self.stack.pop();
        const block_number = block_number_u256.limbs[0];
        const current_block = self.context.block_number;

        // Blockhash is only available for blocks within the last 256 blocks
        // If block_number is outside this range, return 0
        if (block_number >= current_block) {
            try self.stack.push(self.allocator, types.U256.zero());
            self.gas_used += 20;
            return;
        }
        const distance = current_block - block_number;
        if (distance > 256) {
            try self.stack.push(self.allocator, types.U256.zero());
            self.gas_used += 20;
            return;
        }

        if (self.block_hashes.get(block_number)) |hash| {
            try self.stack.push(self.allocator, types.U256.fromBytes(hash.bytes));
        } else {
            try self.stack.push(self.allocator, types.U256.zero());
        }
        self.gas_used += 20;
    }

    fn opSelfBalance(self: *EVM) !void {
        // SELFBALANCE: Balance of the current account (EIP-1884)
        // Equivalent to BALANCE(ADDRESS) but cheaper (5 gas vs 100/2100)
        // Look up balance from state if available
        if (self.state_db) |db| {
            const balance = db.getBalance(self.context.address) catch types.U256.zero();
            try self.stack.push(self.allocator, balance);
        } else {
            // No state database - return 0
            try self.stack.push(self.allocator, types.U256.zero());
        }
        self.gas_used += 5;
    }

    fn opBaseFee(self: *EVM) !void {
        // EIP-1559 base fee - simplified for now
        const base_fee = types.U256.fromU64(1000000000); // 1 gwei
        try self.stack.push(self.allocator, base_fee);
        self.gas_used += 2;
    }

    // SHA3 opcode
    fn opSha3(self: *EVM) !void {
        const offset = try self.stack.pop();
        const length = try self.stack.pop();

        const off = offset.limbs[0];
        const len = length.limbs[0];
        const new_size = off + len;

        // Expand memory if needed
        if (new_size > self.memory.data.items.len) {
            try self.memory.data.resize(new_size);
        }

        const data = self.memory.data.items[off .. off + len];
        var hash: [32]u8 = undefined;
        crypto.keccak256(data, &hash);

        const result = types.U256.fromBytes(hash);
        try self.stack.push(self.allocator, result);

        // Base cost (30) + word cost (6 per word) + memory expansion cost
        const word_count = (len + 31) / 32;
        const mem_cost = self.memoryExpansionCost(new_size);
        self.gas_used += 30 + 6 * word_count + mem_cost;
    }

    // LOG opcodes
    fn opLog(self: *EVM, topic_count: usize) !void {
        const offset = try self.stack.pop();
        const length = try self.stack.pop();

        var topics = try self.allocator.alloc(types.Hash, topic_count);
        for (0..topic_count) |i| {
            const topic_u256 = try self.stack.pop();
            topics[i] = types.Hash{ .bytes = topic_u256.toBytes() };
        }

        const off = offset.limbs[0];
        const len = length.limbs[0];
        const new_size = off + len;

        // Expand memory if needed
        if (new_size > self.memory.data.items.len) {
            try self.memory.data.resize(new_size);
        }

        const data = try self.allocator.alloc(u8, len);
        @memcpy(data, self.memory.data.items[off .. off + len]);

        try self.logs.append(Log{
            .address = self.context.address,
            .topics = topics,
            .data = data,
        });

        // Base cost + topic cost + data cost + memory expansion cost
        const mem_cost = self.memoryExpansionCost(new_size);
        self.gas_used += 375 + 375 * topic_count + 8 * len + mem_cost;
    }

    // REVERT opcode
    fn opRevert(self: *EVM) !void {
        const offset_u256 = try self.stack.pop();
        const length_u256 = try self.stack.pop();
        const offset = offset_u256.limbs[0];
        const length = length_u256.limbs[0];

        const revert_data = try self.readMemoryInput(offset, length);
        defer self.allocator.free(revert_data);
        try self.setReturnData(revert_data);
        self.gas_used += 0;
        return error.Revert;
    }

    fn readMemoryInput(self: *EVM, offset: u64, length: u64) ![]u8 {
        const input = try self.allocator.alloc(u8, length);
        @memset(input, 0);
        if (length == 0 or offset >= self.memory.data.items.len) return input;

        const available_end = @min(offset + length, self.memory.data.items.len);
        const copy_len = available_end - offset;
        if (copy_len > 0) {
            @memcpy(input[0..copy_len], self.memory.data.items[offset..available_end]);
        }
        return input;
    }

    fn writeCallReturn(self: *EVM, ret_offset: u64, ret_length: u64, data: []const u8) !u64 {
        if (ret_length == 0) return 0;
        const new_size = if (ret_offset < 0xFFFFFFFFFFFFFFFF)
            @min(ret_offset + ret_length, 0xFFFFFFFF)
        else
            ret_offset;
        const mem_cost = self.memoryExpansionCost(@intCast(new_size));
        if (new_size > self.memory.data.items.len) {
            try self.memory.data.resize(new_size);
        }
        @memset(self.memory.data.items[ret_offset..][0..ret_length], 0);
        const copy_len = @min(ret_length, data.len);
        if (copy_len > 0) {
            @memcpy(self.memory.data.items[ret_offset..][0..copy_len], data[0..copy_len]);
        }
        return mem_cost;
    }

    fn executeCallFrame(
        self: *EVM,
        code_address: types.Address,
        callee_address: types.Address,
        caller: types.Address,
        call_value: types.U256,
        requested_gas: u64,
        base_gas: u64,
        add_stipend: bool,
        args_offset: u64,
        args_length: u64,
        ret_offset: u64,
        ret_length: u64,
    ) anyerror!bool {
        const calldata = try self.readMemoryInput(args_offset, args_length);
        defer self.allocator.free(calldata);

        var return_data_local: []const u8 = &[_]u8{};
        var return_data_local_owned = false;
        defer if (return_data_local_owned) self.allocator.free(return_data_local);

        var call_success = true;
        var child_logs: []const Log = &[_]Log{};
        var charged_child_gas: u64 = 0;

        const available_gas = self.gas_limit -| self.gas_used;
        const gas_plan = try eip150CallGasPlan(
            available_gas,
            base_gas,
            requested_gas,
            add_stipend,
            !call_value.isZero(),
        );

        if (precompileId(code_address)) |pid| {
            const pc_result = try self.runPrecompile(pid, calldata, gas_plan.forwarded);
            charged_child_gas = pc_result.gas_used;
            call_success = pc_result.success;
            return_data_local = pc_result.output;
            return_data_local_owned = true;
        } else if (self.state_db) |db| {
            const target_code = db.getCode(code_address);
            if (target_code.len > 0) {
                const call_snapshot = try db.snapshot();
                var call_committed = false;
                defer if (!call_committed) db.revertToSnapshot(call_snapshot) catch {};

                var child_ctx = self.context;
                child_ctx.caller = caller;
                child_ctx.origin = self.context.origin;
                child_ctx.address = callee_address;
                child_ctx.value = call_value;
                child_ctx.code = target_code;
                child_ctx.calldata = calldata;

                var child = try EVM.initWithState(self.allocator, gas_plan.child_limit, child_ctx, db);
                defer child.deinit();

                const child_result_opt = blk: {
                    const res = child.execute(target_code, calldata) catch {
                        call_success = false;
                        charged_child_gas = gas_plan.forwarded;
                        // No return data available when child execution fails hard.
                        return_data_local = &[_]u8{};
                        break :blk null;
                    };
                    break :blk res;
                };

                if (child_result_opt) |child_result| {
                    return_data_local = try self.allocator.dupe(u8, child_result.return_data);
                    return_data_local_owned = true;
                    self.allocator.free(child_result.return_data);
                    child_logs = child_result.logs;
                    call_success = child_result.success;
                    charged_child_gas = @min(child_result.gas_used, gas_plan.forwarded);
                    if (child_result.success) {
                        try db.commitSnapshot(call_snapshot);
                        call_committed = true;
                        self.gas_refund += child_result.gas_refund;
                    }
                }
            }
        }

        const mem_cost = try self.writeCallReturn(ret_offset, ret_length, return_data_local);
        try self.setReturnData(return_data_local);
        try self.stack.push(self.allocator, if (call_success) types.U256.one() else types.U256.zero());
        self.gas_used += base_gas + mem_cost + charged_child_gas;

        // Merge child logs only for successful calls.
        if (call_success and child_logs.len > 0) {
            for (child_logs) |log| {
                try self.logs.append(log);
            }
        }
        if (child_logs.len > 0) {
            self.allocator.free(child_logs);
        }
        return call_success;
    }

    fn opCall(self: *EVM) !void {
        const gas = try self.stack.pop();
        const address_u256 = try self.stack.pop();
        const value = try self.stack.pop();
        const args_offset = try self.stack.pop();
        const args_length = try self.stack.pop();
        const ret_offset = try self.stack.pop();
        const ret_length = try self.stack.pop();

        const target = u256ToAddress(address_u256);
        var base_gas: u64 = 700 + try self.accountAccessCost(target);
        if (!value.isZero()) {
            base_gas += 9000;
            if (self.state_db) |db| {
                if (!db.exists(target)) {
                    base_gas += 25000;
                }
            }
        }
        _ = try self.executeCallFrame(
            target,
            target,
            self.context.address,
            value,
            gas.limbs[0],
            base_gas,
            true,
            args_offset.limbs[0],
            args_length.limbs[0],
            ret_offset.limbs[0],
            ret_length.limbs[0],
        );
    }

    fn opStaticCall(self: *EVM) !void {
        const gas = try self.stack.pop();
        const address_u256 = try self.stack.pop();
        const args_offset = try self.stack.pop();
        const args_length = try self.stack.pop();
        const ret_offset = try self.stack.pop();
        const ret_length = try self.stack.pop();

        const target = u256ToAddress(address_u256);
        const base_gas: u64 = 700 + try self.accountAccessCost(target);
        _ = try self.executeCallFrame(
            target,
            target,
            self.context.address,
            types.U256.zero(),
            gas.limbs[0],
            base_gas,
            false,
            args_offset.limbs[0],
            args_length.limbs[0],
            ret_offset.limbs[0],
            ret_length.limbs[0],
        );
    }

    fn opCallCode(self: *EVM) !void {
        const gas = try self.stack.pop();
        const address_u256 = try self.stack.pop();
        const value = try self.stack.pop();
        const args_offset = try self.stack.pop();
        const args_length = try self.stack.pop();
        const ret_offset = try self.stack.pop();
        const ret_length = try self.stack.pop();

        const code_addr = u256ToAddress(address_u256);
        var base_gas: u64 = 700 + try self.accountAccessCost(code_addr);
        if (!value.isZero()) {
            base_gas += 9000;
        }
        _ = try self.executeCallFrame(
            code_addr,
            self.context.address,
            self.context.address,
            value,
            gas.limbs[0],
            base_gas,
            true,
            args_offset.limbs[0],
            args_length.limbs[0],
            ret_offset.limbs[0],
            ret_length.limbs[0],
        );
    }

    fn opDelegateCall(self: *EVM) !void {
        const gas = try self.stack.pop();
        const address_u256 = try self.stack.pop();
        const args_offset = try self.stack.pop();
        const args_length = try self.stack.pop();
        const ret_offset = try self.stack.pop();
        const ret_length = try self.stack.pop();

        const target = u256ToAddress(address_u256);
        const base_gas: u64 = 700 + try self.accountAccessCost(target);
        _ = try self.executeCallFrame(
            target,
            self.context.address,
            self.context.caller,
            self.context.value,
            gas.limbs[0],
            base_gas,
            false,
            args_offset.limbs[0],
            args_length.limbs[0],
            ret_offset.limbs[0],
            ret_length.limbs[0],
        );
    }

    // CREATE opcodes
    fn opCreate(self: *EVM) anyerror!void {
        const value = try self.stack.pop();
        const offset = try self.stack.pop();
        const length = try self.stack.pop();
        const init_code = try self.readMemoryInput(offset.limbs[0], length.limbs[0]);
        defer self.allocator.free(init_code);
        const words = (length.limbs[0] + 31) / 32;
        const copy_gas = words * 3;
        const new_size = if (length.limbs[0] > 0 and offset.limbs[0] < 0xFFFFFFFFFFFFFFFF)
            @min(offset.limbs[0] + length.limbs[0], 0xFFFFFFFF)
        else
            @as(u64, @intCast(self.memory.data.items.len));
        const mem_cost = self.memoryExpansionCost(@intCast(new_size));
        if (new_size > self.memory.data.items.len) {
            try self.memory.data.resize(@intCast(new_size));
        }
        const create_gas = 32000 + mem_cost + copy_gas;
        const available_gas = self.gas_limit -| self.gas_used;
        if (available_gas < create_gas) return error.OutOfGas;
        const child_gas_limit = (available_gas - create_gas) - ((available_gas - create_gas) / 64);

        if (self.state_db == null) {
            try self.stack.push(self.allocator, types.U256.zero());
            self.gas_used += create_gas;
            return;
        }

        const db = self.state_db.?;
        const create_snapshot = try db.snapshot();
        var create_committed = false;
        defer if (!create_committed) db.revertToSnapshot(create_snapshot) catch {};

        const creator_nonce = db.getNonce(self.context.address) catch 0;
        const new_address = deriveCreateAddress(self.context.address, creator_nonce);

        // Value transfer from creator to new account.
        if (!value.isZero()) {
            const creator_balance = db.getBalance(self.context.address) catch types.U256.zero();
            if (creator_balance.lt(value)) {
                try self.stack.push(self.allocator, types.U256.zero());
                self.gas_used += create_gas;
                return;
            }
            try db.setBalance(self.context.address, creator_balance.sub(value));
        }

        try db.createAccount(new_address);
        const callee_balance = db.getBalance(new_address) catch types.U256.zero();
        try db.setBalance(new_address, callee_balance.add(value));
        try db.incrementNonce(self.context.address);

        var child_ctx = self.context;
        child_ctx.address = new_address;
        child_ctx.caller = self.context.address;
        child_ctx.value = value;
        child_ctx.calldata = &[_]u8{};
        child_ctx.code = init_code;

        var child = try EVM.initWithState(self.allocator, child_gas_limit, child_ctx, db);
        defer child.deinit();

        const child_result = child.execute(init_code, &[_]u8{}) catch {
            try self.stack.push(self.allocator, types.U256.zero());
            self.gas_used += create_gas + child_gas_limit;
            return;
        };
        defer if (child_result.return_data.len > 0) self.allocator.free(child_result.return_data);
        defer self.allocator.free(child_result.logs);

        if (!child_result.success) {
            try self.stack.push(self.allocator, types.U256.zero());
            self.gas_used += create_gas + @min(child_result.gas_used, child_gas_limit);
            return;
        }

        try db.setCode(new_address, child_result.return_data);
        try self.setReturnData(child_result.return_data);
        try self.stack.push(self.allocator, addressToU256(new_address));
        self.gas_refund += child_result.gas_refund;
        self.gas_used += create_gas + @min(child_result.gas_used, child_gas_limit);
        try db.commitSnapshot(create_snapshot);
        create_committed = true;
    }

    fn opCreate2(self: *EVM) anyerror!void {
        const value = try self.stack.pop();
        const offset = try self.stack.pop();
        const length = try self.stack.pop();
        const salt = try self.stack.pop();
        const init_code = try self.readMemoryInput(offset.limbs[0], length.limbs[0]);
        defer self.allocator.free(init_code);
        const words = (length.limbs[0] + 31) / 32;
        const copy_gas = words * 3;
        const hash_gas = words * 6; // EIP-1014: GSHA3WORD * ceil(init_code_len / 32)
        const new_size = if (length.limbs[0] > 0 and offset.limbs[0] < 0xFFFFFFFFFFFFFFFF)
            @min(offset.limbs[0] + length.limbs[0], 0xFFFFFFFF)
        else
            @as(u64, @intCast(self.memory.data.items.len));
        const mem_cost = self.memoryExpansionCost(@intCast(new_size));
        if (new_size > self.memory.data.items.len) {
            try self.memory.data.resize(@intCast(new_size));
        }
        const create2_gas = 32000 + mem_cost + copy_gas + hash_gas;
        const available_gas = self.gas_limit -| self.gas_used;
        if (available_gas < create2_gas) return error.OutOfGas;
        const child_gas_limit = (available_gas - create2_gas) - ((available_gas - create2_gas) / 64);

        if (self.state_db == null) {
            try self.stack.push(self.allocator, types.U256.zero());
            self.gas_used += create2_gas;
            return;
        }

        const db = self.state_db.?;
        const create2_snapshot = try db.snapshot();
        var create2_committed = false;
        defer if (!create2_committed) db.revertToSnapshot(create2_snapshot) catch {};

        const new_address = deriveCreate2Address(self.context.address, salt, init_code);

        if (!value.isZero()) {
            const creator_balance = db.getBalance(self.context.address) catch types.U256.zero();
            if (creator_balance.lt(value)) {
                try self.stack.push(self.allocator, types.U256.zero());
                self.gas_used += create2_gas;
                return;
            }
            try db.setBalance(self.context.address, creator_balance.sub(value));
        }

        try db.createAccount(new_address);
        const callee_balance = db.getBalance(new_address) catch types.U256.zero();
        try db.setBalance(new_address, callee_balance.add(value));

        var child_ctx = self.context;
        child_ctx.address = new_address;
        child_ctx.caller = self.context.address;
        child_ctx.value = value;
        child_ctx.calldata = &[_]u8{};
        child_ctx.code = init_code;

        var child = try EVM.initWithState(self.allocator, child_gas_limit, child_ctx, db);
        defer child.deinit();

        const child_result = child.execute(init_code, &[_]u8{}) catch {
            try self.stack.push(self.allocator, types.U256.zero());
            self.gas_used += create2_gas + child_gas_limit;
            return;
        };
        defer if (child_result.return_data.len > 0) self.allocator.free(child_result.return_data);
        defer self.allocator.free(child_result.logs);

        if (!child_result.success) {
            try self.stack.push(self.allocator, types.U256.zero());
            self.gas_used += create2_gas + @min(child_result.gas_used, child_gas_limit);
            return;
        }

        try db.setCode(new_address, child_result.return_data);
        try self.setReturnData(child_result.return_data);
        try self.stack.push(self.allocator, addressToU256(new_address));
        self.gas_refund += child_result.gas_refund;
        self.gas_used += create2_gas + @min(child_result.gas_used, child_gas_limit);
        try db.commitSnapshot(create2_snapshot);
        create2_committed = true;
    }

    // SELFDESTRUCT opcode
    fn opSelfDestruct(self: *EVM) !void {
        const beneficiary = try self.stack.pop();
        const beneficiary_address = u256ToAddress(beneficiary);
        var selfdestruct_gas: u64 = 5000 + try self.accountAccessCost(beneficiary_address);

        if (self.state_db) |db| {
            const from = self.context.address;
            const balance = db.getBalance(from) catch types.U256.zero();
            if (!balance.isZero() and !db.exists(beneficiary_address)) {
                selfdestruct_gas += 25000;
            }

            if (!balance.isZero() and !from.eql(beneficiary_address)) {
                if (!db.exists(beneficiary_address)) {
                    try db.createAccount(beneficiary_address);
                }
                const beneficiary_balance = db.getBalance(beneficiary_address) catch types.U256.zero();
                try db.setBalance(beneficiary_address, beneficiary_balance.add(balance));
            }

            try db.destroyAccount(from);

            if (!self.selfdestructed_accounts.contains(from)) {
                try self.selfdestructed_accounts.put(from, {});
                // EIP-3529: SELFDESTRUCT refund reduced to 4800.
                self.gas_refund += 4800;
            }
        }

        self.gas_used += selfdestruct_gas;
        self.halted = true;
    }

    fn opPush(self: *EVM, code: []const u8, pc: *usize, n: usize) !void {
        var value = types.U256.zero();
        const end = @min(pc.* + n, code.len);

        for (pc.*..end) |i| {
            value = u256Shl(value, 8);
            value.limbs[0] |= @as(u64, code[i]);
        }

        try self.stack.push(self.allocator, value);
        pc.* += n;
        self.gas_used += 3;
    }

    fn opPop(self: *EVM) !void {
        _ = try self.stack.pop();
        self.gas_used += 2;
    }

    fn opMload(self: *EVM) !void {
        const offset = try self.stack.pop();
        const off = offset.limbs[0];
        const new_size = off + 32;

        // Expand memory if needed
        if (new_size > self.memory.data.items.len) {
            try self.memory.data.resize(new_size);
        }

        const value = try self.memory.load(self.allocator, offset);
        try self.stack.push(self.allocator, value);

        // Base cost + memory expansion cost
        const mem_cost = self.memoryExpansionCost(new_size);
        self.gas_used += 3 + mem_cost;
    }

    fn opMstore(self: *EVM) !void {
        const offset = try self.stack.pop();
        const value = try self.stack.pop();
        const off = offset.limbs[0];
        const new_size = off + 32;

        // Expand memory if needed
        if (new_size > self.memory.data.items.len) {
            try self.memory.data.resize(new_size);
        }

        try self.memory.store(self.allocator, offset, value);

        // Base cost + memory expansion cost
        const mem_cost = self.memoryExpansionCost(new_size);
        self.gas_used += 3 + mem_cost;
    }

    fn opMstore8(self: *EVM) !void {
        // MSTORE8: Store single byte at memory offset
        const offset_u256 = try self.stack.pop();
        const value_u256 = try self.stack.pop();
        const offset = offset_u256.limbs[0];
        const byte_value = @as(u8, @truncate(value_u256.limbs[0]));

        const new_size = offset + 1;

        // Expand memory if needed
        if (new_size > self.memory.data.items.len) {
            try self.memory.data.resize(new_size);
        }

        // Store single byte
        self.memory.data.items[offset] = byte_value;

        // Base cost + memory expansion cost
        const mem_cost = self.memoryExpansionCost(new_size);
        self.gas_used += 3 + mem_cost;
    }

    fn opSload(self: *EVM) !void {
        const key = try self.stack.pop();
        const value = if (self.state_db) |db|
            db.getStorage(self.context.address, key) catch types.U256.zero()
        else
            try self.storage.load(key);
        try self.stack.push(self.allocator, value);

        const warm_key = storageWarmKey(self.context.address, key);

        // EIP-2929: 100 gas for warm access, 2100 for cold
        if (self.warm_storage.contains(warm_key)) {
            self.gas_used += 100; // Warm access
        } else {
            self.gas_used += 2100; // Cold access
            try self.warm_storage.put(warm_key, {}); // Mark as warm
        }
    }

    fn opSstore(self: *EVM) !void {
        const key = try self.stack.pop();
        const new_value = try self.stack.pop();
        const current_value = if (self.state_db) |db|
            db.getStorage(self.context.address, key) catch types.U256.zero()
        else
            self.storage.load(key) catch types.U256.zero();

        // EIP-2929: Cold access charge (applied before SSTORE operation cost)
        // EIP-2200: Complex SSTORE gas rules
        // SSTORE costs = cold access charge (if cold) + SSTORE operation cost

        const warm_key = storageWarmKey(self.context.address, key);
        const is_warm = self.warm_storage.contains(warm_key);

        // EIP-2929: Charge cold access cost if this is the first access in transaction
        if (!is_warm) {
            self.gas_used += 2100; // Cold access charge
            try self.warm_storage.put(warm_key, {}); // Mark as warm for subsequent accesses
        }

        // EIP-2200: SSTORE operation costs based on value transitions
        if (current_value.eq(new_value)) {
            // No change: additional cost (cold access already charged above)
            if (is_warm) {
                self.gas_used += 100; // Warm: just operation cost
            }
            // Cold: already charged 2100 above, no additional cost for no-change
        } else if (!current_value.isZero() and new_value.isZero()) {
            // Delete: operation cost
            if (is_warm) {
                self.gas_used += 100; // Warm delete
            } else {
                // Cold delete: 2100 already charged, operation cost is 0 (refund case)
            }
            // EIP-3529: SSTORE clear refund
            self.gas_refund += 4800;
        } else if (current_value.isZero() and !new_value.isZero()) {
            // Set new value: 20000 gas for the SSTORE operation
            self.gas_used += 20000;
        } else {
            // Update existing value: operation cost
            if (is_warm) {
                self.gas_used += 5000; // Warm update
            } else {
                // Cold update: 2100 already charged, add operation cost
                self.gas_used += 800; // 2900 - 2100 = 800 (since we already charged cold access)
            }
        }

        if (self.state_db) |db| {
            try db.setStorage(self.context.address, key, new_value);
        } else {
            try self.storage.store(key, new_value);
        }
    }

    fn opJump(self: *EVM, pc: *usize) !void {
        const dest = try self.stack.pop();
        pc.* = dest.limbs[0];
        self.gas_used += 8;
    }

    fn opJumpi(self: *EVM, pc: *usize) !void {
        const dest = try self.stack.pop();
        const condition = try self.stack.pop();

        if (!condition.isZero()) {
            pc.* = dest.limbs[0];
        }
        self.gas_used += 10;
    }

    fn opReturn(self: *EVM) !void {
        const offset_u256 = try self.stack.pop();
        const length_u256 = try self.stack.pop();
        const offset = offset_u256.limbs[0];
        const length = length_u256.limbs[0];

        const returned = try self.readMemoryInput(offset, length);
        defer self.allocator.free(returned);
        try self.setReturnData(returned);
        self.halted = true;
        self.gas_used += 0;
    }

    fn opReturnDataSize(self: *EVM) !void {
        // Return size of data from last CALL/CREATE/DELEGATECALL
        // For now, return 0 (will be populated when CALL operations return data)
        const size = types.U256.fromU64(self.return_data.len);
        try self.stack.push(self.allocator, size);
        self.gas_used += 2;
    }

    fn opReturnDataCopy(self: *EVM) !void {
        // Stack: memOffset, returnDataOffset, length
        const mem_offset_u256 = try self.stack.pop();
        const return_data_offset_u256 = try self.stack.pop();
        const length_u256 = try self.stack.pop();

        const mem_offset = mem_offset_u256.limbs[0];
        const return_data_offset = return_data_offset_u256.limbs[0];
        const length = length_u256.limbs[0];

        // Check bounds - revert if out of bounds
        if (return_data_offset + length > self.return_data.len) {
            return error.Revert; // Out of bounds access
        }

        // Calculate required memory size
        const new_size = if (length > 0 and mem_offset < 0xFFFFFFFFFFFFFFFF)
            @min(mem_offset + length, 0xFFFFFFFF)
        else
            mem_offset;

        // Expand memory if needed
        if (new_size > self.memory.data.items.len) {
            try self.memory.data.resize(new_size);
        }

        // Copy from return data to memory
        if (length > 0) {
            @memcpy(self.memory.data.items[mem_offset..][0..length], self.return_data[return_data_offset .. return_data_offset + length]);
        }

        // Gas cost: 3 base + memory expansion + copy cost
        const mem_cost = self.memoryExpansionCost(new_size);
        const copy_cost = (length + 31) / 32; // Words to copy (minimum 1)
        self.gas_used += 3 + mem_cost + copy_cost;
    }
};

/// EVM opcodes (now with 60+ opcodes!)
pub const Opcode = enum(u8) {
    // 0s: Stop and Arithmetic
    STOP = 0x00,
    ADD = 0x01,
    MUL = 0x02,
    SUB = 0x03,
    DIV = 0x04,
    SDIV = 0x05,
    MOD = 0x06,
    SMOD = 0x07,
    ADDMOD = 0x08,
    MULMOD = 0x09,
    EXP = 0x0a,
    SIGNEXTEND = 0x0b,

    // 10s: Comparison & Bitwise Logic
    LT = 0x10,
    GT = 0x11,
    SLT = 0x12,
    SGT = 0x13,
    EQ = 0x14,
    ISZERO = 0x15,
    AND = 0x16,
    OR = 0x17,
    XOR = 0x18,
    NOT = 0x19,
    BYTE = 0x1a,
    SHL = 0x1b,
    SHR = 0x1c,
    SAR = 0x1d,

    // 20s: SHA3
    SHA3 = 0x20,

    // 30s: Environmental Information
    ADDRESS = 0x30,
    BALANCE = 0x31,
    ORIGIN = 0x32,
    CALLER = 0x33,
    CALLVALUE = 0x34,
    CALLDATALOAD = 0x35,
    CALLDATASIZE = 0x36,
    CALLDATACOPY = 0x37,
    CODESIZE = 0x38,
    CODECOPY = 0x39,
    GASPRICE = 0x3a,
    EXTCODESIZE = 0x3b,
    EXTCODECOPY = 0x3c,
    RETURNDATASIZE = 0x3d,
    RETURNDATACOPY = 0x3e,
    EXTCODEHASH = 0x3f,

    // 40s: Block Information
    BLOCKHASH = 0x40,
    COINBASE = 0x41,
    TIMESTAMP = 0x42,
    NUMBER = 0x43,
    DIFFICULTY = 0x44,
    GASLIMIT = 0x45,
    CHAINID = 0x46,
    SELFBALANCE = 0x47,
    BASEFEE = 0x48,

    // 50s: Stack, Memory, Storage and Flow Operations
    POP = 0x50,
    MLOAD = 0x51,
    MSTORE = 0x52,
    MSTORE8 = 0x53,
    SLOAD = 0x54,
    SSTORE = 0x55,
    JUMP = 0x56,
    JUMPI = 0x57,
    PC = 0x58,
    MSIZE = 0x59,
    GAS = 0x5a,
    JUMPDEST = 0x5b,

    // 60s & 70s: Push Operations
    PUSH1 = 0x60,
    PUSH2 = 0x61,
    PUSH3 = 0x62,
    PUSH4 = 0x63,
    PUSH5 = 0x64,
    PUSH6 = 0x65,
    PUSH7 = 0x66,
    PUSH8 = 0x67,
    PUSH9 = 0x68,
    PUSH10 = 0x69,
    PUSH11 = 0x6a,
    PUSH12 = 0x6b,
    PUSH13 = 0x6c,
    PUSH14 = 0x6d,
    PUSH15 = 0x6e,
    PUSH16 = 0x6f,
    PUSH17 = 0x70,
    PUSH18 = 0x71,
    PUSH19 = 0x72,
    PUSH20 = 0x73,
    PUSH21 = 0x74,
    PUSH22 = 0x75,
    PUSH23 = 0x76,
    PUSH24 = 0x77,
    PUSH25 = 0x78,
    PUSH26 = 0x79,
    PUSH27 = 0x7a,
    PUSH28 = 0x7b,
    PUSH29 = 0x7c,
    PUSH30 = 0x7d,
    PUSH31 = 0x7e,
    PUSH32 = 0x7f,

    // 80s: Duplication Operations
    DUP1 = 0x80,
    DUP2 = 0x81,
    DUP3 = 0x82,
    DUP4 = 0x83,
    DUP5 = 0x84,
    DUP6 = 0x85,
    DUP7 = 0x86,
    DUP8 = 0x87,
    DUP9 = 0x88,
    DUP10 = 0x89,
    DUP11 = 0x8a,
    DUP12 = 0x8b,
    DUP13 = 0x8c,
    DUP14 = 0x8d,
    DUP15 = 0x8e,
    DUP16 = 0x8f,

    // 90s: Exchange Operations
    SWAP1 = 0x90,
    SWAP2 = 0x91,
    SWAP3 = 0x92,
    SWAP4 = 0x93,
    SWAP5 = 0x94,
    SWAP6 = 0x95,
    SWAP7 = 0x96,
    SWAP8 = 0x97,
    SWAP9 = 0x98,
    SWAP10 = 0x99,
    SWAP11 = 0x9a,
    SWAP12 = 0x9b,
    SWAP13 = 0x9c,
    SWAP14 = 0x9d,
    SWAP15 = 0x9e,
    SWAP16 = 0x9f,

    // a0s: Logging Operations
    LOG0 = 0xa0,
    LOG1 = 0xa1,
    LOG2 = 0xa2,
    LOG3 = 0xa3,
    LOG4 = 0xa4,

    // f0s: System Operations
    CREATE = 0xf0,
    CALL = 0xf1,
    CALLCODE = 0xf2,
    RETURN = 0xf3,
    DELEGATECALL = 0xf4,
    CREATE2 = 0xf5,
    STATICCALL = 0xfa,
    REVERT = 0xfd,
    INVALID = 0xfe,
    SELFDESTRUCT = 0xff,

    _,
};

const Stack = struct {
    items: std.ArrayList(types.U256),
    const max_depth = 1024;

    fn init(allocator: std.mem.Allocator) !Stack {
        return Stack{
            .items = try std.ArrayList(types.U256).initCapacity(allocator, 32),
        };
    }

    fn deinit(self: *Stack, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.items.deinit();
    }

    pub fn push(self: *Stack, allocator: std.mem.Allocator, value: types.U256) !void {
        if (self.items.items.len >= max_depth) {
            return error.StackOverflow;
        }
        _ = allocator;
        try self.items.append(value);
    }

    pub fn pop(self: *Stack) !types.U256 {
        if (self.items.items.len == 0) {
            return error.StackUnderflow;
        }
        return self.items.pop() orelse return error.StackUnderflow;
    }
};

const Memory = struct {
    data: std.ArrayList(u8),

    fn init(allocator: std.mem.Allocator) !Memory {
        return Memory{
            .data = try std.ArrayList(u8).initCapacity(allocator, 256),
        };
    }

    fn deinit(self: *Memory, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.data.deinit();
    }

    fn load(self: *Memory, allocator: std.mem.Allocator, offset: types.U256) !types.U256 {
        const off = offset.limbs[0];
        if (off + 32 > self.data.items.len) {
            _ = allocator;
            try self.data.resize(off + 32);
        }

        var bytes: [32]u8 = undefined;
        @memcpy(&bytes, self.data.items[off..][0..32]);
        return types.U256.fromBytes(bytes);
    }

    fn store(self: *Memory, allocator: std.mem.Allocator, offset: types.U256, value: types.U256) !void {
        const off = offset.limbs[0];
        if (off + 32 > self.data.items.len) {
            _ = allocator;
            try self.data.resize(off + 32);
        }

        const bytes = value.toBytes();
        @memcpy(self.data.items[off..][0..32], &bytes);
    }
};

const Storage = struct {
    data: std.AutoHashMap(types.U256, types.U256),

    fn init(allocator: std.mem.Allocator) Storage {
        return Storage{
            .data = std.AutoHashMap(types.U256, types.U256).init(allocator),
        };
    }

    fn deinit(self: *Storage) void {
        self.data.deinit();
    }

    pub fn load(self: *Storage, key: types.U256) !types.U256 {
        return self.data.get(key) orelse types.U256.zero();
    }

    pub fn store(self: *Storage, key: types.U256, value: types.U256) !void {
        try self.data.put(key, value);
    }
};

pub const ExecutionResult = struct {
    success: bool,
    gas_used: u64,
    gas_refund: u64,
    return_data: []const u8,
    logs: []const Log,

    // Store return data for RETURNDATACOPY
    return_data_allocator: ?std.mem.Allocator = null,
    return_data_owned: ?[]u8 = null,
};

pub const Log = struct {
    address: types.Address,
    topics: []types.Hash,
    data: []const u8,
};

test "EVM stack operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var evm = try EVM.init(allocator, 1000000);
    defer evm.deinit();

    try evm.stack.push(allocator, types.U256.fromU64(10));
    try evm.stack.push(allocator, types.U256.fromU64(20));

    const b = try evm.stack.pop();
    const a = try evm.stack.pop();

    try testing.expectEqual(@as(u64, 10), a.limbs[0]);
    try testing.expectEqual(@as(u64, 20), b.limbs[0]);
}

test "EVM simple addition" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var evm = try EVM.init(allocator, 1000000);
    defer evm.deinit();

    // PUSH1 5, PUSH1 3, ADD
    const code = [_]u8{ 0x60, 0x05, 0x60, 0x03, 0x01 };
    _ = try evm.execute(&code, &[_]u8{});

    const result = try evm.stack.pop();
    try testing.expectEqual(@as(u64, 8), result.limbs[0]);
}

test "EVM EIP-150 call gas plan applies 63/64 cap" {
    const testing = std.testing;

    const plan = try EVM.eip150CallGasPlan(
        100_000, // available
        700, // base
        100_000, // requested
        false, // stipend
        false, // value
    );
    // available_after_base = 99,300; cap = 99,300 - floor(99,300/64) = 97,749
    try testing.expectEqual(@as(u64, 97_749), plan.forwarded);
    try testing.expectEqual(@as(u64, 97_749), plan.child_limit);
}

test "EVM EIP-150 call gas plan adds stipend for value transfer" {
    const testing = std.testing;

    const plan = try EVM.eip150CallGasPlan(
        50_000, // available
        12_300, // base (700 + 2600 + 9000)
        30_000, // requested
        true, // stipend-eligible opcode
        true, // non-zero value
    );
    try testing.expectEqual(@as(u64, 30_000), plan.forwarded);
    try testing.expectEqual(@as(u64, 32_300), plan.child_limit);
}
