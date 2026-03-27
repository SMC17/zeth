//! EVMC plugin: C ABI bridge for Zeth EVM.
//! Build: zig build evmc -> libzeth_evmc.so / libzeth_evmc.dylib
//! Client loads via dlopen and resolves evmc_create_zeth().
//!
//! This module implements the EVMC v12 interface, allowing any EVMC-compatible
//! client (geth, Silkworm, Besu, etc.) to use Zeth as an execution backend.

const std = @import("std");
const evm_mod = @import("evm");
const types = @import("types");

// ---------------------------------------------------------------------------
// EVMC ABI constants
// ---------------------------------------------------------------------------

/// EVMC ABI version.  Must match the client's evmc.h.
const EVMC_ABI_VERSION: c_int = 12;

const ZETH_VM_NAME: [*:0]const u8 = "zeth";
const ZETH_VM_VERSION: [*:0]const u8 = "0.2.0-evmc";

// -- status codes (evmc_status_code) --
const EVMC_SUCCESS: c_int = 0;
const EVMC_FAILURE: c_int = 1;
const EVMC_REVERT: c_int = 2;
const EVMC_OUT_OF_GAS: c_int = 3;
const EVMC_INVALID_INSTRUCTION: c_int = 4;
const EVMC_UNDEFINED_INSTRUCTION: c_int = 5;
const EVMC_STACK_OVERFLOW: c_int = 6;
const EVMC_STACK_UNDERFLOW: c_int = 7;
const EVMC_BAD_JUMP_DESTINATION: c_int = 8;
const EVMC_INVALID_MEMORY_ACCESS: c_int = 9;
const EVMC_INTERNAL_ERROR: c_int = -1;
const EVMC_REJECTED: c_int = -2;

// -- message kind (evmc_call_kind) --
const EVMC_CALL: c_int = 0;
const EVMC_DELEGATECALL: c_int = 1;
const EVMC_CALLCODE: c_int = 2;
const EVMC_CREATE: c_int = 3;
const EVMC_CREATE2: c_int = 4;

// -- EVM revision (evmc_revision) --
const EVMC_FRONTIER: c_int = 0;
const EVMC_HOMESTEAD: c_int = 1;
const EVMC_TANGERINE_WHISTLE: c_int = 2;
const EVMC_SPURIOUS_DRAGON: c_int = 3;
const EVMC_BYZANTIUM: c_int = 4;
const EVMC_CONSTANTINOPLE: c_int = 5;
const EVMC_PETERSBURG: c_int = 6;
const EVMC_ISTANBUL: c_int = 7;
const EVMC_BERLIN: c_int = 8;
const EVMC_LONDON: c_int = 9;
const EVMC_PARIS: c_int = 10;
const EVMC_SHANGHAI: c_int = 11;
const EVMC_CANCUN: c_int = 12;

// -- storage status (evmc_storage_status) --
const EVMC_STORAGE_ASSIGNED: c_int = 0;
const EVMC_STORAGE_ADDED: c_int = 1;
const EVMC_STORAGE_DELETED: c_int = 2;
const EVMC_STORAGE_MODIFIED: c_int = 3;
const EVMC_STORAGE_DELETED_ADDED: c_int = 4;
const EVMC_STORAGE_MODIFIED_DELETED: c_int = 5;
const EVMC_STORAGE_DELETED_RESTORED: c_int = 6;
const EVMC_STORAGE_ADDED_DELETED: c_int = 7;
const EVMC_STORAGE_MODIFIED_RESTORED: c_int = 8;

// -- access status (evmc_access_status) --
const EVMC_ACCESS_COLD: c_int = 0;
const EVMC_ACCESS_WARM: c_int = 1;

// -- capabilities (evmc_capabilities) --
const EVMC_CAPABILITY_EVM1: u32 = 1;

// ---------------------------------------------------------------------------
// EVMC C ABI types
// ---------------------------------------------------------------------------

const evmc_address = extern struct { bytes: [20]u8 };
const evmc_bytes32 = extern struct { bytes: [32]u8 };

const evmc_result = extern struct {
    status_code: c_int,
    gas_left: i64,
    gas_refund: i64,
    output_data: ?[*]const u8,
    output_size: usize,
    release: ?*const fn (*const evmc_result) callconv(.C) void,
    create_address: evmc_address,
    padding: [4]u8,
};

const evmc_message = extern struct {
    kind: c_int,
    flags: u32,
    depth: i32,
    gas: i64,
    recipient: evmc_address,
    sender: evmc_address,
    input_data: ?[*]const u8,
    input_size: usize,
    value: evmc_bytes32,
    create2_salt: evmc_bytes32,
    code_address: evmc_address,
    code: ?[*]const u8,
    code_size: usize,
};

const evmc_tx_context = extern struct {
    tx_gas_price: evmc_bytes32,
    tx_origin: evmc_address,
    block_coinbase: evmc_address,
    block_number: i64,
    block_timestamp: i64,
    block_gas_limit: i64,
    block_prev_randao: evmc_bytes32,
    chain_id: evmc_bytes32,
    block_base_fee: evmc_bytes32,
    blob_base_fee: evmc_bytes32,
    blob_hashes: ?[*]const evmc_bytes32,
    blob_hashes_count: usize,
};

const evmc_host_context = opaque {};

// ---------------------------------------------------------------------------
// EVMC host interface — function pointer table provided by the client
// ---------------------------------------------------------------------------

const evmc_host_interface = extern struct {
    account_exists: *const fn (*const evmc_host_context, *const evmc_address) callconv(.C) bool,
    get_storage: *const fn (*const evmc_host_context, *const evmc_address, *const evmc_bytes32) callconv(.C) evmc_bytes32,
    set_storage: *const fn (*const evmc_host_context, *const evmc_address, *const evmc_bytes32, *const evmc_bytes32) callconv(.C) c_int,
    get_balance: *const fn (*const evmc_host_context, *const evmc_address) callconv(.C) evmc_bytes32,
    get_code_size: *const fn (*const evmc_host_context, *const evmc_address) callconv(.C) usize,
    get_code_hash: *const fn (*const evmc_host_context, *const evmc_address) callconv(.C) evmc_bytes32,
    copy_code: *const fn (*const evmc_host_context, *const evmc_address, usize, [*]u8, usize) callconv(.C) usize,
    selfdestruct: *const fn (*const evmc_host_context, *const evmc_address, *const evmc_address) callconv(.C) bool,
    call: *const fn (*const evmc_host_context, *const evmc_message) callconv(.C) evmc_result,
    get_tx_context: *const fn (*const evmc_host_context) callconv(.C) evmc_tx_context,
    get_block_hash: *const fn (*const evmc_host_context, i64) callconv(.C) evmc_bytes32,
    emit_log: *const fn (*const evmc_host_context, *const evmc_address, ?[*]const u8, usize, ?[*]const evmc_bytes32, usize) callconv(.C) void,
    access_account: *const fn (*const evmc_host_context, *const evmc_address) callconv(.C) c_int,
    access_storage: *const fn (*const evmc_host_context, *const evmc_address, *const evmc_bytes32) callconv(.C) c_int,
};

// ---------------------------------------------------------------------------
// EVMC VM struct — the top-level object returned by evmc_create_zeth()
// ---------------------------------------------------------------------------

const evmc_vm = extern struct {
    abi_version: c_int,
    name: [*:0]const u8,
    version: [*:0]const u8,
    destroy: *const fn (*evmc_vm) callconv(.C) void,
    execute: *const fn (
        *const evmc_vm,
        *const evmc_host_interface,
        *const evmc_host_context,
        c_int, // revision
        *const evmc_message,
        ?[*]const u8, // code
        usize, // code_size
    ) callconv(.C) evmc_result,
    get_capabilities: *const fn (*const evmc_vm) callconv(.C) u32,
    set_option: ?*const fn (*evmc_vm, [*:0]const u8, [*:0]const u8) callconv(.C) c_int,
};

// ---------------------------------------------------------------------------
// Conversion helpers: EVMC <-> Zeth types
// ---------------------------------------------------------------------------

fn evmcAddrToZeth(addr: *const evmc_address) types.Address {
    return types.Address{ .bytes = addr.bytes };
}

fn zethAddrToEvmc(addr: types.Address) evmc_address {
    return evmc_address{ .bytes = addr.bytes };
}

fn evmcBytes32ToU256(b32: evmc_bytes32) types.U256 {
    return types.U256.fromBytes(b32.bytes);
}

fn u256ToEvmcBytes32(v: types.U256) evmc_bytes32 {
    return evmc_bytes32{ .bytes = v.toBytes() };
}

fn evmcBytes32ToHash(b32: evmc_bytes32) types.Hash {
    return types.Hash{ .bytes = b32.bytes };
}

fn zeroBytes32() evmc_bytes32 {
    return evmc_bytes32{ .bytes = [_]u8{0} ** 32 };
}

fn zeroAddress() evmc_address {
    return evmc_address{ .bytes = [_]u8{0} ** 20 };
}

// ---------------------------------------------------------------------------
// Result helpers
// ---------------------------------------------------------------------------

fn makeErrorResult(status: c_int, gas_left: i64) evmc_result {
    return evmc_result{
        .status_code = status,
        .gas_left = gas_left,
        .gas_refund = 0,
        .output_data = null,
        .output_size = 0,
        .release = null,
        .create_address = zeroAddress(),
        .padding = [_]u8{0} ** 4,
    };
}

/// Release callback for results whose output_data was allocated with C malloc.
fn releaseResult(result: *const evmc_result) callconv(.C) void {
    if (result.output_size > 0) {
        if (result.output_data) |ptr| {
            std.c.free(@constCast(@ptrCast(ptr)));
        }
    }
}

/// Duplicate a byte slice into C-heap memory suitable for evmc_result output.
fn dupeOutputForEvmc(data: []const u8) ?[*]const u8 {
    if (data.len == 0) return null;
    const raw = std.c.malloc(data.len) orelse return null;
    const buf: [*]u8 = @ptrCast(raw);
    @memcpy(buf[0..data.len], data);
    return buf;
}

// ---------------------------------------------------------------------------
// HostStateAdapter — bridges EVMC host callbacks to Zeth's internal StateDB
// interface so the EVM can call SLOAD/SSTORE/BALANCE/etc.
//
// For the MVP, the EVM runs without a real StateDB.  State-accessing opcodes
// use the EVM's internal storage map (works for pure computation).  The
// adapter is prepared here so that a future version can wire host callbacks
// through for full state access.
// ---------------------------------------------------------------------------

const HostBridge = struct {
    host: *const evmc_host_interface,
    context: *const evmc_host_context,

    fn accountExists(self: *const HostBridge, addr: types.Address) bool {
        var evmc_addr = zethAddrToEvmc(addr);
        return self.host.account_exists(self.context, &evmc_addr);
    }

    fn getBalance(self: *const HostBridge, addr: types.Address) types.U256 {
        var evmc_addr = zethAddrToEvmc(addr);
        const b32 = self.host.get_balance(self.context, &evmc_addr);
        return evmcBytes32ToU256(b32);
    }

    fn getStorage(self: *const HostBridge, addr: types.Address, key: types.U256) types.U256 {
        var evmc_addr = zethAddrToEvmc(addr);
        var evmc_key = u256ToEvmcBytes32(key);
        const b32 = self.host.get_storage(self.context, &evmc_addr, &evmc_key);
        return evmcBytes32ToU256(b32);
    }

    fn setStorage(self: *const HostBridge, addr: types.Address, key: types.U256, value: types.U256) c_int {
        var evmc_addr = zethAddrToEvmc(addr);
        var evmc_key = u256ToEvmcBytes32(key);
        var evmc_val = u256ToEvmcBytes32(value);
        return self.host.set_storage(self.context, &evmc_addr, &evmc_key, &evmc_val);
    }

    fn getCodeSize(self: *const HostBridge, addr: types.Address) usize {
        var evmc_addr = zethAddrToEvmc(addr);
        return self.host.get_code_size(self.context, &evmc_addr);
    }

    fn getCodeHash(self: *const HostBridge, addr: types.Address) types.Hash {
        var evmc_addr = zethAddrToEvmc(addr);
        const b32 = self.host.get_code_hash(self.context, &evmc_addr);
        return evmcBytes32ToHash(b32);
    }

    fn getTxContext(self: *const HostBridge) evmc_tx_context {
        return self.host.get_tx_context(self.context);
    }

    fn getBlockHash(self: *const HostBridge, number: i64) types.Hash {
        const b32 = self.host.get_block_hash(self.context, number);
        return evmcBytes32ToHash(b32);
    }

    fn emitLog(self: *const HostBridge, addr: types.Address, data: []const u8, topic_hashes: []const types.Hash) void {
        var evmc_addr = zethAddrToEvmc(addr);
        // topics are layout-compatible (both [32]u8 inner), so reinterpret
        const topics_ptr: ?[*]const evmc_bytes32 = if (topic_hashes.len > 0)
            @ptrCast(topic_hashes.ptr)
        else
            null;
        const data_ptr: ?[*]const u8 = if (data.len > 0) data.ptr else null;
        self.host.emit_log(self.context, &evmc_addr, data_ptr, data.len, topics_ptr, topic_hashes.len);
    }

    fn accessAccount(self: *const HostBridge, addr: types.Address) c_int {
        var evmc_addr = zethAddrToEvmc(addr);
        return self.host.access_account(self.context, &evmc_addr);
    }

    fn accessStorage(self: *const HostBridge, addr: types.Address, key: types.U256) c_int {
        var evmc_addr = zethAddrToEvmc(addr);
        var evmc_key = u256ToEvmcBytes32(key);
        return self.host.access_storage(self.context, &evmc_addr, &evmc_key);
    }
};

// ---------------------------------------------------------------------------
// Core execute: converts EVMC message -> Zeth EVM, runs bytecode, converts back
// ---------------------------------------------------------------------------

fn zeth_execute(
    vm: *const evmc_vm,
    host: *const evmc_host_interface,
    host_ctx: *const evmc_host_context,
    rev: c_int,
    msg: *const evmc_message,
    code_ptr: ?[*]const u8,
    code_size: usize,
) callconv(.C) evmc_result {
    _ = vm;
    _ = rev; // TODO: gate features by revision

    // Reject non-EVM1 call kinds we don't handle yet.
    if (msg.kind != EVMC_CALL and msg.kind != EVMC_DELEGATECALL and
        msg.kind != EVMC_CALLCODE and msg.kind != EVMC_CREATE and
        msg.kind != EVMC_CREATE2)
    {
        return makeErrorResult(EVMC_REJECTED, msg.gas);
    }

    const code: []const u8 = if (code_ptr) |p| p[0..code_size] else &[_]u8{};

    // If there is no code to execute, return success immediately (value transfer only).
    if (code.len == 0) {
        return evmc_result{
            .status_code = EVMC_SUCCESS,
            .gas_left = msg.gas,
            .gas_refund = 0,
            .output_data = null,
            .output_size = 0,
            .release = null,
            .create_address = zeroAddress(),
            .padding = [_]u8{0} ** 4,
        };
    }

    // Build the host bridge (available for future state-accessing opcode support).
    const bridge = HostBridge{
        .host = host,
        .context = host_ctx,
    };

    // Fetch tx context from the host to populate our ExecutionContext.
    const tx_ctx = bridge.getTxContext();

    const calldata: []const u8 = if (msg.input_data) |p| p[0..msg.input_size] else &[_]u8{};

    var ctx = evm_mod.ExecutionContext{
        .caller = evmcAddrToZeth(&msg.sender),
        .origin = evmcAddrToZeth(&tx_ctx.tx_origin),
        .address = evmcAddrToZeth(&msg.recipient),
        .value = evmcBytes32ToU256(msg.value),
        .calldata = calldata,
        .code = code,
        .block_number = @intCast(@max(tx_ctx.block_number, 0)),
        .block_timestamp = @intCast(@max(tx_ctx.block_timestamp, 0)),
        .block_coinbase = evmcAddrToZeth(&tx_ctx.block_coinbase),
        .block_difficulty = evmcBytes32ToU256(tx_ctx.block_prev_randao),
        .block_gaslimit = @intCast(@max(tx_ctx.block_gas_limit, 0)),
        .chain_id = chainIdFromBytes32(tx_ctx.chain_id),
        .block_base_fee = baseFeeFromBytes32(tx_ctx.block_base_fee),
        .block_prev_randao = evmcBytes32ToU256(tx_ctx.block_prev_randao),
    };
    _ = &ctx;

    // Allocator: use the page allocator for the EVM arena.  This is coarse but
    // safe from a C-ABI shared library where we cannot rely on caller allocators.
    const allocator = std.heap.page_allocator;

    const gas_limit: u64 = if (msg.gas > 0) @intCast(msg.gas) else 0;

    var evm_instance = evm_mod.EVM.initWithContext(allocator, gas_limit, ctx) catch {
        return makeErrorResult(EVMC_INTERNAL_ERROR, msg.gas);
    };
    defer evm_instance.deinit();

    // Execute.
    const exec_result = evm_instance.execute(code, calldata) catch |err| {
        const status: c_int = mapZethError(err);
        const gas_left = gasLeft(gas_limit, evm_instance.gas_used);
        return makeErrorResult(status, gas_left);
    };

    const gas_left = gasLeft(gas_limit, exec_result.gas_used);
    const gas_refund: i64 = @intCast(exec_result.gas_refund);

    if (!exec_result.success) {
        // REVERT path — return output data (reason) but with REVERT status.
        const out_ptr = dupeOutputForEvmc(exec_result.return_data);
        return evmc_result{
            .status_code = EVMC_REVERT,
            .gas_left = gas_left,
            .gas_refund = gas_refund,
            .output_data = out_ptr,
            .output_size = exec_result.return_data.len,
            .release = if (out_ptr != null) &releaseResult else null,
            .create_address = zeroAddress(),
            .padding = [_]u8{0} ** 4,
        };
    }

    // SUCCESS
    const out_ptr = dupeOutputForEvmc(exec_result.return_data);
    return evmc_result{
        .status_code = EVMC_SUCCESS,
        .gas_left = gas_left,
        .gas_refund = gas_refund,
        .output_data = out_ptr,
        .output_size = exec_result.return_data.len,
        .release = if (out_ptr != null) &releaseResult else null,
        .create_address = zeroAddress(),
        .padding = [_]u8{0} ** 4,
    };
}

fn gasLeft(limit: u64, used: u64) i64 {
    if (used >= limit) return 0;
    return @intCast(limit - used);
}

fn mapZethError(err: anyerror) c_int {
    return switch (err) {
        error.OutOfGas => EVMC_OUT_OF_GAS,
        error.StackOverflow => EVMC_STACK_OVERFLOW,
        error.StackUnderflow => EVMC_STACK_UNDERFLOW,
        error.InvalidOpcode => EVMC_UNDEFINED_INSTRUCTION,
        error.InvalidJumpDest => EVMC_BAD_JUMP_DESTINATION,
        error.Revert => EVMC_REVERT,
        else => EVMC_FAILURE,
    };
}

/// Extract chain_id as u64 from a big-endian bytes32.
fn chainIdFromBytes32(b32: evmc_bytes32) u64 {
    const v = types.U256.fromBytes(b32.bytes);
    return v.limbs[0]; // Only the low 64 bits matter for chain ID.
}

/// Extract base fee as ?u64 from a big-endian bytes32.
fn baseFeeFromBytes32(b32: evmc_bytes32) ?u64 {
    const v = types.U256.fromBytes(b32.bytes);
    if (v.isZero()) return null;
    return v.limbs[0];
}

// ---------------------------------------------------------------------------
// VM lifecycle
// ---------------------------------------------------------------------------

fn zeth_destroy(vm: *evmc_vm) callconv(.C) void {
    // The VM is statically allocated; nothing to free.
    _ = vm;
}

fn zeth_get_capabilities(vm: *const evmc_vm) callconv(.C) u32 {
    _ = vm;
    return EVMC_CAPABILITY_EVM1;
}

fn zeth_set_option(vm: *evmc_vm, name: [*:0]const u8, value: [*:0]const u8) callconv(.C) c_int {
    _ = vm;
    _ = name;
    _ = value;
    // No options supported yet.  Return 1 to indicate "unknown option".
    return 1;
}

// ---------------------------------------------------------------------------
// Static VM instance
// ---------------------------------------------------------------------------

var vm_instance = evmc_vm{
    .abi_version = EVMC_ABI_VERSION,
    .name = ZETH_VM_NAME,
    .version = ZETH_VM_VERSION,
    .destroy = &zeth_destroy,
    .execute = &zeth_execute,
    .get_capabilities = &zeth_get_capabilities,
    .set_option = &zeth_set_option,
};

/// Entry point.  Clients call this after dlopen() to get the VM handle.
export fn evmc_create_zeth() callconv(.C) *evmc_vm {
    return &vm_instance;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

// Minimal mock host — returns defaults for all callbacks.
const MockHost = struct {
    fn accountExists(_: *const evmc_host_context, _: *const evmc_address) callconv(.C) bool {
        return false;
    }
    fn getStorage(_: *const evmc_host_context, _: *const evmc_address, _: *const evmc_bytes32) callconv(.C) evmc_bytes32 {
        return zeroBytes32();
    }
    fn setStorage(_: *const evmc_host_context, _: *const evmc_address, _: *const evmc_bytes32, _: *const evmc_bytes32) callconv(.C) c_int {
        return EVMC_STORAGE_ASSIGNED;
    }
    fn getBalance(_: *const evmc_host_context, _: *const evmc_address) callconv(.C) evmc_bytes32 {
        return zeroBytes32();
    }
    fn getCodeSize(_: *const evmc_host_context, _: *const evmc_address) callconv(.C) usize {
        return 0;
    }
    fn getCodeHash(_: *const evmc_host_context, _: *const evmc_address) callconv(.C) evmc_bytes32 {
        return zeroBytes32();
    }
    fn copyCode(_: *const evmc_host_context, _: *const evmc_address, _: usize, _: [*]u8, _: usize) callconv(.C) usize {
        return 0;
    }
    fn selfDestruct(_: *const evmc_host_context, _: *const evmc_address, _: *const evmc_address) callconv(.C) bool {
        return false;
    }
    fn call(_: *const evmc_host_context, _: *const evmc_message) callconv(.C) evmc_result {
        return makeErrorResult(EVMC_FAILURE, 0);
    }
    fn getTxContext(_: *const evmc_host_context) callconv(.C) evmc_tx_context {
        return evmc_tx_context{
            .tx_gas_price = zeroBytes32(),
            .tx_origin = zeroAddress(),
            .block_coinbase = zeroAddress(),
            .block_number = 1,
            .block_timestamp = 1_700_000_000,
            .block_gas_limit = 30_000_000,
            .block_prev_randao = zeroBytes32(),
            .chain_id = chainIdToBytes32(1),
            .block_base_fee = zeroBytes32(),
            .blob_base_fee = zeroBytes32(),
            .blob_hashes = null,
            .blob_hashes_count = 0,
        };
    }
    fn getBlockHash(_: *const evmc_host_context, _: i64) callconv(.C) evmc_bytes32 {
        return zeroBytes32();
    }
    fn emitLog(_: *const evmc_host_context, _: *const evmc_address, _: ?[*]const u8, _: usize, _: ?[*]const evmc_bytes32, _: usize) callconv(.C) void {}
    fn accessAccount(_: *const evmc_host_context, _: *const evmc_address) callconv(.C) c_int {
        return EVMC_ACCESS_COLD;
    }
    fn accessStorage(_: *const evmc_host_context, _: *const evmc_address, _: *const evmc_bytes32) callconv(.C) c_int {
        return EVMC_ACCESS_COLD;
    }

    fn chainIdToBytes32(id: u64) evmc_bytes32 {
        return u256ToEvmcBytes32(types.U256.fromU64(id));
    }

    const iface = evmc_host_interface{
        .account_exists = &accountExists,
        .get_storage = &getStorage,
        .set_storage = &setStorage,
        .get_balance = &getBalance,
        .get_code_size = &getCodeSize,
        .get_code_hash = &getCodeHash,
        .copy_code = &copyCode,
        .selfdestruct = &selfDestruct,
        .call = &call,
        .get_tx_context = &getTxContext,
        .get_block_hash = &getBlockHash,
        .emit_log = &emitLog,
        .access_account = &accessAccount,
        .access_storage = &accessStorage,
    };
};

/// A stand-in for the opaque host context pointer used in tests.
/// We do not dereference it in the mock host, so a null-like sentinel is fine.
fn mockHostContext() *const evmc_host_context {
    return @ptrFromInt(0x1); // non-null sentinel
}

test "evmc_create_zeth returns valid VM" {
    const vm = evmc_create_zeth();
    try testing.expectEqual(EVMC_ABI_VERSION, vm.abi_version);

    // Check name
    const name: [*:0]const u8 = vm.name;
    try testing.expect(name[0] == 'z' and name[1] == 'e' and name[2] == 't' and name[3] == 'h' and name[4] == 0);

    // Capabilities
    const caps = vm.get_capabilities(vm);
    try testing.expect((caps & EVMC_CAPABILITY_EVM1) != 0);
}

test "execute empty code returns success" {
    const vm = evmc_create_zeth();
    const msg = evmc_message{
        .kind = EVMC_CALL,
        .flags = 0,
        .depth = 0,
        .gas = 100000,
        .recipient = zeroAddress(),
        .sender = zeroAddress(),
        .input_data = null,
        .input_size = 0,
        .value = zeroBytes32(),
        .create2_salt = zeroBytes32(),
        .code_address = zeroAddress(),
        .code = null,
        .code_size = 0,
    };

    const result = vm.execute(vm, &MockHost.iface, mockHostContext(), EVMC_SHANGHAI, &msg, null, 0);
    try testing.expectEqual(EVMC_SUCCESS, result.status_code);
    try testing.expectEqual(@as(i64, 100000), result.gas_left);
}

test "execute PUSH1 0x42 PUSH1 0x00 MSTORE PUSH1 0x20 PUSH1 0x00 RETURN" {
    const vm = evmc_create_zeth();

    // Bytecode: PUSH1 0x42 PUSH1 0x00 MSTORE PUSH1 0x20 PUSH1 0x00 RETURN
    // This stores 0x42 at memory[0] and returns 32 bytes from offset 0.
    const code = [_]u8{
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x00, // PUSH1 0x00
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 0x20
        0x60, 0x00, // PUSH1 0x00
        0xf3, // RETURN
    };

    const msg = evmc_message{
        .kind = EVMC_CALL,
        .flags = 0,
        .depth = 0,
        .gas = 100000,
        .recipient = zeroAddress(),
        .sender = zeroAddress(),
        .input_data = null,
        .input_size = 0,
        .value = zeroBytes32(),
        .create2_salt = zeroBytes32(),
        .code_address = zeroAddress(),
        .code = &code,
        .code_size = code.len,
    };

    const result = vm.execute(vm, &MockHost.iface, mockHostContext(), EVMC_SHANGHAI, &msg, &code, code.len);
    try testing.expectEqual(EVMC_SUCCESS, result.status_code);
    try testing.expect(result.gas_left > 0);
    try testing.expectEqual(@as(usize, 32), result.output_size);

    // The returned 32 bytes should have 0x42 in the last byte (big-endian MSTORE).
    if (result.output_data) |out| {
        try testing.expectEqual(@as(u8, 0x42), out[31]);
    } else {
        return error.TestUnexpectedResult;
    }

    // Release output
    if (result.release) |rel| {
        rel(&result);
    }
}

test "execute ADD: PUSH1 3 PUSH1 5 ADD PUSH1 0x00 MSTORE PUSH1 0x20 PUSH1 0x00 RETURN" {
    const vm = evmc_create_zeth();

    // 3 + 5 = 8, store result and return it.
    const code = [_]u8{
        0x60, 0x03, // PUSH1 3
        0x60, 0x05, // PUSH1 5
        0x01, // ADD
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
    };

    const msg = evmc_message{
        .kind = EVMC_CALL,
        .flags = 0,
        .depth = 0,
        .gas = 100000,
        .recipient = zeroAddress(),
        .sender = zeroAddress(),
        .input_data = null,
        .input_size = 0,
        .value = zeroBytes32(),
        .create2_salt = zeroBytes32(),
        .code_address = zeroAddress(),
        .code = &code,
        .code_size = code.len,
    };

    const result = vm.execute(vm, &MockHost.iface, mockHostContext(), EVMC_SHANGHAI, &msg, &code, code.len);
    try testing.expectEqual(EVMC_SUCCESS, result.status_code);
    try testing.expectEqual(@as(usize, 32), result.output_size);

    if (result.output_data) |out| {
        try testing.expectEqual(@as(u8, 8), out[31]);
    } else {
        return error.TestUnexpectedResult;
    }

    if (result.release) |rel| {
        rel(&result);
    }
}

test "execute out of gas" {
    const vm = evmc_create_zeth();

    // Infinite loop: JUMPDEST PUSH1 0x00 JUMP
    const code = [_]u8{
        0x5b, // JUMPDEST (pc=0)
        0x60, 0x00, // PUSH1 0x00
        0x56, // JUMP -> pc 0
    };

    const msg = evmc_message{
        .kind = EVMC_CALL,
        .flags = 0,
        .depth = 0,
        .gas = 100, // Very small gas limit
        .recipient = zeroAddress(),
        .sender = zeroAddress(),
        .input_data = null,
        .input_size = 0,
        .value = zeroBytes32(),
        .create2_salt = zeroBytes32(),
        .code_address = zeroAddress(),
        .code = &code,
        .code_size = code.len,
    };

    const result = vm.execute(vm, &MockHost.iface, mockHostContext(), EVMC_SHANGHAI, &msg, &code, code.len);
    try testing.expectEqual(EVMC_OUT_OF_GAS, result.status_code);
    try testing.expectEqual(@as(i64, 0), result.gas_left);
}

test "execute REVERT returns status and data" {
    const vm = evmc_create_zeth();

    // PUSH1 0xAA PUSH1 0x00 MSTORE PUSH1 0x01 PUSH1 0x1f REVERT
    // Stores 0xAA at memory[31], then reverts returning 1 byte from offset 31.
    const code = [_]u8{
        0x60, 0xAA, // PUSH1 0xAA
        0x60, 0x00, // PUSH1 0x00
        0x52, // MSTORE (stores 32 bytes, 0xAA at position 31)
        0x60, 0x01, // PUSH1 0x01  (size = 1)
        0x60, 0x1f, // PUSH1 0x1f  (offset = 31)
        0xfd, // REVERT
    };

    const msg = evmc_message{
        .kind = EVMC_CALL,
        .flags = 0,
        .depth = 0,
        .gas = 100000,
        .recipient = zeroAddress(),
        .sender = zeroAddress(),
        .input_data = null,
        .input_size = 0,
        .value = zeroBytes32(),
        .create2_salt = zeroBytes32(),
        .code_address = zeroAddress(),
        .code = &code,
        .code_size = code.len,
    };

    const result = vm.execute(vm, &MockHost.iface, mockHostContext(), EVMC_SHANGHAI, &msg, &code, code.len);
    try testing.expectEqual(EVMC_REVERT, result.status_code);
    try testing.expectEqual(@as(usize, 1), result.output_size);

    if (result.output_data) |out| {
        try testing.expectEqual(@as(u8, 0xAA), out[0]);
    } else {
        return error.TestUnexpectedResult;
    }

    if (result.release) |rel| {
        rel(&result);
    }
}

test "conversion round-trip: U256 <-> evmc_bytes32" {
    const val = types.U256.fromU64(0xDEADBEEF);
    const b32 = u256ToEvmcBytes32(val);
    const back = evmcBytes32ToU256(b32);
    try testing.expect(val.eq(back));
}

test "conversion round-trip: Address <-> evmc_address" {
    var addr = types.Address.zero;
    addr.bytes[0] = 0x42;
    addr.bytes[19] = 0xFF;
    const evmc_addr = zethAddrToEvmc(addr);
    const back = evmcAddrToZeth(&evmc_addr);
    try testing.expect(addr.eql(back));
}
