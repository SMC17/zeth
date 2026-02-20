//! zeth-sim: clean execution API for EVM simulation.
//! Provides a minimal, stable interface over the core EVM runtime.

const std = @import("std");
const evm = @import("evm");
const types = @import("types");
const state = @import("state");

pub const U256 = types.U256;
pub const Address = types.Address;
pub const Hash = types.Hash;

/// Execution request with context overrides.
pub const ExecutionRequest = struct {
    address: Address = Address.zero,
    caller: Address = Address.zero,
    origin: Address = Address.zero,
    value: U256 = U256.zero(),
    block_number: u64 = 0,
    block_timestamp: u64 = 0,
    block_coinbase: Address = Address.zero,
    block_difficulty: U256 = U256.zero(),
    block_gaslimit: u64 = 30_000_000,
    block_base_fee: ?u64 = null,
    chain_id: u64 = 1,
    gas_limit: u64 = 30_000_000,

    pub fn default() ExecutionRequest {
        return .{};
    }

    pub fn toContext(self: ExecutionRequest) evm.ExecutionContext {
        return .{
            .caller = self.caller,
            .origin = self.origin,
            .address = self.address,
            .value = self.value,
            .calldata = &[_]u8{},
            .code = &[_]u8{},
            .block_number = self.block_number,
            .block_timestamp = self.block_timestamp,
            .block_coinbase = self.block_coinbase,
            .block_difficulty = self.block_difficulty,
            .block_gaslimit = self.block_gaslimit,
            .chain_id = self.chain_id,
            .block_base_fee = self.block_base_fee,
        };
    }
};

/// Execution result wrapper for library users.
pub const ExecutionResult = struct {
    success: bool,
    gas_used: u64,
    gas_refund: u64,
    return_data: []const u8,
    logs: []const evm.Log,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *ExecutionResult) void {
        if (self.return_data.len > 0) self.allocator.free(self.return_data);
        self.allocator.free(@constCast(self.logs));
    }
};

/// Execute bytecode with context only.
pub fn execute(
    allocator: std.mem.Allocator,
    code: []const u8,
    calldata: []const u8,
    req: ExecutionRequest,
) !ExecutionResult {
    var ctx = req.toContext();
    ctx.calldata = calldata;
    ctx.code = code;

    var vm = try evm.EVM.initWithContext(allocator, req.gas_limit, ctx);
    defer vm.deinit();

    const raw = try vm.execute(code, calldata);

    return .{
        .success = raw.success,
        .gas_used = raw.gas_used,
        .gas_refund = raw.gas_refund,
        .return_data = raw.return_data,
        .logs = raw.logs,
        .allocator = allocator,
    };
}

/// Execute with injected state backend.
pub fn executeWithState(
    allocator: std.mem.Allocator,
    code: []const u8,
    calldata: []const u8,
    req: ExecutionRequest,
    state_db: *state.StateDB,
) !ExecutionResult {
    var ctx = req.toContext();
    ctx.calldata = calldata;
    ctx.code = code;

    var vm = try evm.EVM.initWithState(allocator, req.gas_limit, ctx, state_db);
    defer vm.deinit();

    const raw = try vm.execute(code, calldata);

    return .{
        .success = raw.success,
        .gas_used = raw.gas_used,
        .gas_refund = raw.gas_refund,
        .return_data = raw.return_data,
        .logs = raw.logs,
        .allocator = allocator,
    };
}

test "sim: basic execution" {
    const a = std.testing.allocator;
    var req = ExecutionRequest.default();
    req.gas_limit = 100_000;

    const code = [_]u8{ 0x60, 0x2a, 0x60, 0x03, 0x01, 0x00 }; // PUSH1 0x2a, PUSH1 3, ADD, STOP
    var result = try execute(a, &code, &[_]u8{}, req);
    defer result.deinit();

    try std.testing.expect(result.success);
    try std.testing.expect(result.gas_used > 0);
}
