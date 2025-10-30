const std = @import("std");
const types = @import("types");
const crypto = @import("crypto");

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
        };
    }
};

/// Ethereum Virtual Machine implementation
pub const EVM = struct {
    allocator: std.mem.Allocator,
    gas_limit: u64,
    gas_used: u64,
    stack: Stack,
    memory: Memory,
    storage: Storage,
    context: ExecutionContext,
    logs: std.ArrayList(Log),
    // Track warm storage accesses for EIP-2200
    warm_storage: std.AutoHashMap(types.U256, void),

    pub fn init(allocator: std.mem.Allocator, gas_limit: u64) !EVM {
        return EVM{
            .allocator = allocator,
            .gas_limit = gas_limit,
            .gas_used = 0,
            .stack = try Stack.init(allocator),
            .memory = try Memory.init(allocator),
            .storage = Storage.init(allocator),
            .context = ExecutionContext.default(),
            .logs = try std.ArrayList(Log).initCapacity(allocator, 0),
            .warm_storage = std.AutoHashMap(types.U256, void).init(allocator),
        };
    }
    
    pub fn initWithContext(allocator: std.mem.Allocator, gas_limit: u64, context: ExecutionContext) !EVM {
        return EVM{
            .allocator = allocator,
            .gas_limit = gas_limit,
            .gas_used = 0,
            .stack = try Stack.init(allocator),
            .memory = try Memory.init(allocator),
            .storage = Storage.init(allocator),
            .context = context,
            .logs = try std.ArrayList(Log).initCapacity(allocator, 0),
            .warm_storage = std.AutoHashMap(types.U256, void).init(allocator),
        };
    }

    pub fn deinit(self: *EVM) void {
        self.stack.deinit(self.allocator);
        self.memory.deinit(self.allocator);
        self.storage.deinit();
        self.logs.deinit(self.allocator);
        self.warm_storage.deinit();
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

    pub fn execute(self: *EVM, code: []const u8, data: []const u8) !ExecutionResult {
        self.context.code = code;
        self.context.calldata = data;
        var pc: usize = 0;

        while (pc < code.len) {
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
                        .return_data = &[_]u8{},
                        .logs = &[_]Log{},
                    };
                }
                return err;
            };
        }

        return ExecutionResult{
            .success = true,
            .gas_used = self.gas_used,
            .return_data = &[_]u8{},
            .logs = try self.logs.toOwnedSlice(self.allocator),
        };
    }

    fn executeOpcode(self: *EVM, opcode: Opcode, code: []const u8, pc: *usize) !void {
        switch (opcode) {
            .STOP => return,
            
            // Arithmetic
            .ADD => try self.opAdd(),
            .MUL => try self.opMul(),
            .SUB => try self.opSub(),
            .DIV => try self.opDiv(),
            .MOD => try self.opMod(),
            .EXP => try self.opExp(),
            
            // Comparison
            .LT => try self.opLt(),
            .GT => try self.opGt(),
            .EQ => try self.opEq(),
            .ISZERO => try self.opIsZero(),
            
            // Bitwise
            .AND => try self.opAnd(),
            .OR => try self.opOr(),
            .XOR => try self.opXor(),
            .NOT => try self.opNot(),
            .SHL => try self.opShl(),
            .SHR => try self.opShr(),
            
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
            .CODESIZE => try self.opCodeSize(),
            .GASPRICE => try self.opGasPrice(),
            
            // Block information
            .COINBASE => try self.opCoinbase(),
            .TIMESTAMP => try self.opTimestamp(),
            .NUMBER => try self.opNumber(),
            .DIFFICULTY => try self.opDifficulty(),
            .GASLIMIT => try self.opGasLimit(),
            .CHAINID => try self.opChainId(),
            .BASEFEE => try self.opBaseFee(),
            
            // Hashing
            .SHA3 => try self.opSha3(),
            
            // Logging
            .LOG0 => try self.opLog(0),
            .LOG1 => try self.opLog(1),
            .LOG2 => try self.opLog(2),
            .LOG3 => try self.opLog(3),
            .LOG4 => try self.opLog(4),
            
            // System
            .RETURN => try self.opReturn(),
            .REVERT => try self.opRevert(),
            .CALL => try self.opCall(),
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
    
    fn opExp(self: *EVM) !void {
        const base = try self.stack.pop();
        const exponent = try self.stack.pop();
        
        // TODO: Implement actual exponentiation
        // For now, just push base (placeholder)
        try self.stack.push(self.allocator, base);
        
        // Gas cost: 10 + 50 * (number of bytes to represent exponent)
        // Count significant bytes in exponent (leading zeros don't count)
        var exp_bytes: u64 = 0;
        var has_nonzero = false;
        for (exponent.toBytes()) |byte| {
            if (byte != 0) {
                has_nonzero = true;
            }
            if (has_nonzero) {
                exp_bytes += 1;
            }
        }
        if (exp_bytes == 0) exp_bytes = 1; // At least 1 byte
        
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
    
    fn opShl(self: *EVM) !void {
        const shift = try self.stack.pop();
        const value = try self.stack.pop();
        _ = shift;
        try self.stack.push(self.allocator, value); // TODO: Implement shift
        self.gas_used += 3;
    }
    
    fn opShr(self: *EVM) !void {
        const shift = try self.stack.pop();
        const value = try self.stack.pop();
        _ = shift;
        try self.stack.push(self.allocator, value); // TODO: Implement shift
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
        var value = types.U256.zero();
        // Address is 20 bytes, store in last 20 bytes of U256 (bytes 12-31 in big-endian)
        // U256 is 32 bytes: bytes[0] is MSB, bytes[31] is LSB
        // Address goes in bytes[12..32] (last 20 bytes)
        const addr_bytes = self.context.address.bytes;
        var result_bytes = value.toBytes();
        @memcpy(result_bytes[12..32], addr_bytes[0..20]);
        value = types.U256.fromBytes(result_bytes);
        try self.stack.push(self.allocator, value);
        self.gas_used += 2;
    }
    
    fn opCaller(self: *EVM) !void {
        var value = types.U256.zero();
        const caller_bytes = self.context.caller.bytes;
        var result_bytes = value.toBytes();
        @memcpy(result_bytes[12..32], caller_bytes[0..20]);
        value = types.U256.fromBytes(result_bytes);
        try self.stack.push(self.allocator, value);
        self.gas_used += 2;
    }
    
    fn opOrigin(self: *EVM) !void {
        var value = types.U256.zero();
        const origin_bytes = self.context.origin.bytes;
        var result_bytes = value.toBytes();
        @memcpy(result_bytes[12..32], origin_bytes[0..20]);
        value = types.U256.fromBytes(result_bytes);
        try self.stack.push(self.allocator, value);
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
    
    fn opCodeSize(self: *EVM) !void {
        const size = types.U256.fromU64(self.context.code.len);
        try self.stack.push(self.allocator, size);
        self.gas_used += 2;
    }
    
    fn opGasPrice(self: *EVM) !void {
        // Fixed gas price for now
        const price = types.U256.fromU64(20000000000); // 20 gwei
        try self.stack.push(self.allocator, price);
        self.gas_used += 2;
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
            try self.memory.data.resize(self.allocator, new_size);
        }
        
        const data = self.memory.data.items[off..off + len];
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
            try self.memory.data.resize(self.allocator, new_size);
        }
        
        const data = try self.allocator.alloc(u8, len);
        @memcpy(data, self.memory.data.items[off..off + len]);
        
        try self.logs.append(self.allocator, Log{
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
        _ = try self.stack.pop(); // offset
        _ = try self.stack.pop(); // length
        self.gas_used += 0;
        return error.Revert;
    }
    
    // CALL opcodes - simplified implementations
    fn opCall(self: *EVM) !void {
        const gas = try self.stack.pop();
        const address_u256 = try self.stack.pop();
        const value = try self.stack.pop();
        const args_offset = try self.stack.pop();
        const args_length = try self.stack.pop();
        const ret_offset = try self.stack.pop();
        const ret_length = try self.stack.pop();
        
        // Simplified CALL - just push success for now
        // TODO: Actually execute called contract code
        _ = gas;
        _ = address_u256;
        _ = value;
        _ = args_offset;
        _ = args_length;
        _ = ret_offset;
        _ = ret_length;
        
        try self.stack.push(self.allocator, types.U256.one()); // Success
        self.gas_used += 700;
    }
    
    fn opStaticCall(self: *EVM) !void {
        const gas = try self.stack.pop();
        const address = try self.stack.pop();
        const args_offset = try self.stack.pop();
        const args_length = try self.stack.pop();
        const ret_offset = try self.stack.pop();
        const ret_length = try self.stack.pop();
        
        // Simplified STATICCALL
        _ = gas;
        _ = address;
        _ = args_offset;
        _ = args_length;
        _ = ret_offset;
        _ = ret_length;
        
        try self.stack.push(self.allocator, types.U256.one()); // Success
        self.gas_used += 700;
    }
    
    fn opDelegateCall(self: *EVM) !void {
        const gas = try self.stack.pop();
        const address = try self.stack.pop();
        const args_offset = try self.stack.pop();
        const args_length = try self.stack.pop();
        const ret_offset = try self.stack.pop();
        const ret_length = try self.stack.pop();
        
        // Simplified DELEGATECALL
        _ = gas;
        _ = address;
        _ = args_offset;
        _ = args_length;
        _ = ret_offset;
        _ = ret_length;
        
        try self.stack.push(self.allocator, types.U256.one()); // Success
        self.gas_used += 700;
    }
    
    // CREATE opcodes
    fn opCreate(self: *EVM) !void {
        const value = try self.stack.pop();
        const offset = try self.stack.pop();
        const length = try self.stack.pop();
        
        // Simplified CREATE - return mock address
        _ = value;
        _ = offset;
        _ = length;
        
        // Return a mock contract address
        const mock_address = types.U256.fromU64(0x1234567890);
        try self.stack.push(self.allocator, mock_address);
        self.gas_used += 32000;
    }
    
    fn opCreate2(self: *EVM) !void {
        const value = try self.stack.pop();
        const offset = try self.stack.pop();
        const length = try self.stack.pop();
        const salt = try self.stack.pop();
        
        // Simplified CREATE2
        _ = value;
        _ = offset;
        _ = length;
        _ = salt;
        
        // Return a mock contract address
        const mock_address = types.U256.fromU64(0x9876543210);
        try self.stack.push(self.allocator, mock_address);
        self.gas_used += 32000;
    }
    
    // SELFDESTRUCT opcode
    fn opSelfDestruct(self: *EVM) !void {
        const beneficiary = try self.stack.pop();
        _ = beneficiary;
        
        // Mark for deletion - in real implementation would transfer balance
        self.gas_used += 5000;
        return error.SelfDestruct;
    }

    fn opPush(self: *EVM, code: []const u8, pc: *usize, n: usize) !void {
        var value = types.U256.zero();
        const end = @min(pc.* + n, code.len);
        
        for (pc.*..end) |i| {
            value.limbs[0] = (value.limbs[0] << 8) | code[i];
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
            try self.memory.data.resize(self.allocator, new_size);
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
            try self.memory.data.resize(self.allocator, new_size);
        }
        
        try self.memory.store(self.allocator, offset, value);
        
        // Base cost + memory expansion cost
        const mem_cost = self.memoryExpansionCost(new_size);
        self.gas_used += 3 + mem_cost;
    }

    fn opSload(self: *EVM) !void {
        const key = try self.stack.pop();
        const value = try self.storage.load(key);
        try self.stack.push(self.allocator, value);
        
        // EIP-2929: 100 gas for warm access, 2100 for cold
        if (self.warm_storage.contains(key)) {
            self.gas_used += 100; // Warm access
        } else {
            self.gas_used += 2100; // Cold access
            try self.warm_storage.put(key, {}); // Mark as warm
        }
    }

    fn opSstore(self: *EVM) !void {
        const key = try self.stack.pop();
        const new_value = try self.stack.pop();
        const current_value = self.storage.load(key) catch types.U256.zero();
        
        // EIP-2200: Complex SSTORE gas rules
        // Simplified implementation:
        // - If current == new: 100 (warm) or 2100 (cold)
        // - If current != 0 and new == 0: refund 4800
        // - If current == 0 and new != 0: 20000 (cold) or 2900 (warm)
        // - If current != 0 and new != 0 and current != new: 5000 (warm) or 2900 (cold, but then becomes warm)
        
        const is_warm = self.warm_storage.contains(key);
        
        if (current_value.eq(new_value)) {
            // No change
            self.gas_used += if (is_warm) 100 else 2100;
        } else if (!current_value.isZero() and new_value.isZero()) {
            // Delete (refund)
            if (is_warm) {
                self.gas_used += 100;
            } else {
                self.gas_used += 2100;
            }
            // Refund handled separately (not implemented yet)
        } else if (current_value.isZero() and !new_value.isZero()) {
            // Set new value
            if (is_warm) {
                self.gas_used += 2900;
            } else {
                self.gas_used += 20000;
                try self.warm_storage.put(key, {}); // Mark as warm
            }
        } else {
            // Update existing value
            if (is_warm) {
                self.gas_used += 5000;
            } else {
                self.gas_used += 2900;
                try self.warm_storage.put(key, {}); // Mark as warm
            }
        }
        
        try self.storage.store(key, new_value);
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
        _ = try self.stack.pop(); // offset
        _ = try self.stack.pop(); // length
        self.gas_used += 0;
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
        self.items.deinit(allocator);
    }

    pub fn push(self: *Stack, allocator: std.mem.Allocator, value: types.U256) !void {
        if (self.items.items.len >= max_depth) {
            return error.StackOverflow;
        }
        try self.items.append(allocator, value);
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
        self.data.deinit(allocator);
    }

    fn load(self: *Memory, allocator: std.mem.Allocator, offset: types.U256) !types.U256 {
        const off = offset.limbs[0];
        if (off + 32 > self.data.items.len) {
            try self.data.resize(allocator, off + 32);
        }
        
        var bytes: [32]u8 = undefined;
        @memcpy(&bytes, self.data.items[off..][0..32]);
        return types.U256.fromBytes(bytes);
    }

    fn store(self: *Memory, allocator: std.mem.Allocator, offset: types.U256, value: types.U256) !void {
        const off = offset.limbs[0];
        if (off + 32 > self.data.items.len) {
            try self.data.resize(allocator, off + 32);
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
    return_data: []const u8,
    logs: []const Log,
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

