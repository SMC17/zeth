const std = @import("std");
const types = @import("types");

/// Ethereum Virtual Machine implementation
pub const EVM = struct {
    allocator: std.mem.Allocator,
    gas_limit: u64,
    gas_used: u64,
    stack: Stack,
    memory: Memory,
    storage: Storage,

    pub fn init(allocator: std.mem.Allocator, gas_limit: u64) !EVM {
        return EVM{
            .allocator = allocator,
            .gas_limit = gas_limit,
            .gas_used = 0,
            .stack = try Stack.init(allocator),
            .memory = try Memory.init(allocator),
            .storage = Storage.init(allocator),
        };
    }

    pub fn deinit(self: *EVM) void {
        self.stack.deinit(self.allocator);
        self.memory.deinit(self.allocator);
        self.storage.deinit();
    }

    pub fn execute(self: *EVM, code: []const u8, data: []const u8) !ExecutionResult {
        _ = data;
        var pc: usize = 0;

        while (pc < code.len) {
            if (self.gas_used >= self.gas_limit) {
                return error.OutOfGas;
            }

            const opcode = @as(Opcode, @enumFromInt(code[pc]));
            pc += 1;

            try self.executeOpcode(opcode, code, &pc);
        }

        return ExecutionResult{
            .success = true,
            .gas_used = self.gas_used,
            .return_data = &[_]u8{},
        };
    }

    fn executeOpcode(self: *EVM, opcode: Opcode, code: []const u8, pc: *usize) !void {
        switch (opcode) {
            .STOP => return,
            .ADD => try self.opAdd(),
            .MUL => try self.opMul(),
            .SUB => try self.opSub(),
            .DIV => try self.opDiv(),
            .PUSH1 => try self.opPush(code, pc, 1),
            .PUSH32 => try self.opPush(code, pc, 32),
            .POP => try self.opPop(),
            .MLOAD => try self.opMload(),
            .MSTORE => try self.opMstore(),
            .SLOAD => try self.opSload(),
            .SSTORE => try self.opSstore(),
            .JUMP => try self.opJump(pc),
            .JUMPI => try self.opJumpi(pc),
            .RETURN => try self.opReturn(),
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
        _ = b;
        try self.stack.push(self.allocator, a); // Simplified
        self.gas_used += 5;
    }

    fn opSub(self: *EVM) !void {
        const a = try self.stack.pop();
        const b = try self.stack.pop();
        _ = b;
        try self.stack.push(self.allocator, a); // Simplified
        self.gas_used += 3;
    }

    fn opDiv(self: *EVM) !void {
        const a = try self.stack.pop();
        const b = try self.stack.pop();
        if (b.isZero()) {
            try self.stack.push(self.allocator, types.U256.zero());
        } else {
            try self.stack.push(self.allocator, a); // Simplified
        }
        self.gas_used += 5;
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
        const value = try self.memory.load(self.allocator, offset);
        try self.stack.push(self.allocator, value);
        self.gas_used += 3;
    }

    fn opMstore(self: *EVM) !void {
        const offset = try self.stack.pop();
        const value = try self.stack.pop();
        try self.memory.store(self.allocator, offset, value);
        self.gas_used += 3;
    }

    fn opSload(self: *EVM) !void {
        const key = try self.stack.pop();
        const value = try self.storage.load(key);
        try self.stack.push(self.allocator, value);
        self.gas_used += 200;
    }

    fn opSstore(self: *EVM) !void {
        const key = try self.stack.pop();
        const value = try self.stack.pop();
        try self.storage.store(key, value);
        self.gas_used += 5000;
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

/// EVM opcodes
pub const Opcode = enum(u8) {
    STOP = 0x00,
    ADD = 0x01,
    MUL = 0x02,
    SUB = 0x03,
    DIV = 0x04,
    POP = 0x50,
    MLOAD = 0x51,
    MSTORE = 0x52,
    SLOAD = 0x54,
    SSTORE = 0x55,
    JUMP = 0x56,
    JUMPI = 0x57,
    PUSH1 = 0x60,
    PUSH32 = 0x7f,
    RETURN = 0xf3,
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

    fn push(self: *Stack, allocator: std.mem.Allocator, value: types.U256) !void {
        if (self.items.items.len >= max_depth) {
            return error.StackOverflow;
        }
        try self.items.append(allocator, value);
    }

    fn pop(self: *Stack) !types.U256 {
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

    fn load(self: *Storage, key: types.U256) !types.U256 {
        return self.data.get(key) orelse types.U256.zero();
    }

    fn store(self: *Storage, key: types.U256, value: types.U256) !void {
        try self.data.put(key, value);
    }
};

pub const ExecutionResult = struct {
    success: bool,
    gas_used: u64,
    return_data: []const u8,
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

