//! EVMC plugin: C ABI shim for Zeth.
//! Build: zig build evmc → libzeth_evmc.so / libzeth_evmc.dylib
//! Client loads and resolves evmc_create_zeth().

const std = @import("std");

// EVMC status codes (evmc_status_code)
const EVMC_SUCCESS: c_int = 0;
const EVMC_FAILURE: c_int = 1;
const EVMC_REVERT: c_int = 2;
const EVMC_OUT_OF_GAS: c_int = 3;
const EVMC_REJECTED: c_int = -2;

// Minimal evmc types for C ABI compatibility
const evmc_address = extern struct { bytes: [20]u8 };
const evmc_bytes32 = extern struct { bytes: [32]u8 };

const evmc_result = extern struct {
    status_code: c_int,
    gas_left: i64,
    gas_refund: i64,
    output_data: [*]const u8,
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
    input_data: [*]const u8,
    input_size: usize,
    value: evmc_bytes32,
    create2_salt: evmc_bytes32,
    code_address: evmc_address,
    code: [*]const u8,
    code_size: usize,
};

const evmc_host_context = opaque {};
const evmc_vm = opaque {};

const evmc_execute_fn = *const fn (
    *const evmc_vm,
    *const evmc_host_context,
    c_int,
    *const evmc_message,
    [*]const u8,
    usize,
) callconv(.C) evmc_result;

const evmc_destroy_fn = *const fn (*evmc_vm) callconv(.C) void;

// VM instance - static, no per-instance data needed for stub
var vm_name: [*:0]const u8 = "zeth";
var vm_version: [*:0]const u8 = "0.1.0-evmc";

fn zeth_destroy(vm: *evmc_vm) callconv(.C) void {
    _ = vm;
    // Static instance, nothing to free
}

fn zeth_execute(
    vm: *const evmc_vm,
    host: *const evmc_host_context,
    rev: c_int,
    msg: *const evmc_message,
    code: [*]const u8,
    code_size: usize,
) callconv(.C) evmc_result {
    _ = vm;
    _ = host;
    _ = rev;
    _ = msg;
    _ = code;
    _ = code_size;
    // Stub: return REJECTED until full host bridge is implemented
    return .{
        .status_code = EVMC_REJECTED,
        .gas_left = 0,
        .gas_refund = 0,
        .output_data = undefined,
        .output_size = 0,
        .release = null,
        .create_address = .{ .bytes = [_]u8{0} ** 20 },
        .padding = [_]u8{0} ** 4,
    };
}

const VM_SIZE = 64;
var vm_storage: [VM_SIZE]u8 align(8) = undefined;

export fn evmc_create_zeth() callconv(.C) *evmc_vm {
    // Minimal evmc_vm-like layout: abi_version, name, version, destroy, execute
    // Layout per EVMC: int abi_version, char* name, char* version, destroy_fn, execute_fn, ...
    const P = struct {
        abi_version: c_int,
        name: [*]const u8,
        version: [*]const u8,
        destroy: evmc_destroy_fn,
        execute: evmc_execute_fn,
    };
    var p: *P = @ptrCast(@alignCast(&vm_storage));
    p.abi_version = 12;
    p.name = vm_name;
    p.version = vm_version;
    p.destroy = zeth_destroy;
    p.execute = zeth_execute;
    return @ptrCast(p);
}
