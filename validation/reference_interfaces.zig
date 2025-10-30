const std = @import("std");
const types = @import("types");

/// Interface to reference Ethereum implementations (Geth, PyEVM)
/// Uses subprocess execution to run bytecode and compare results

pub const ReferenceResult = struct {
    success: bool,
    gas_used: u64,
    return_data: []const u8,
    stack: []types.U256,
    error_message: ?[]const u8,
    allocator: std.mem.Allocator,
    
    pub fn deinit(self: *ReferenceResult) void {
        self.allocator.free(self.return_data);
        for (self.stack) |item| {
            _ = item; // U256 doesn't need deinit
        }
        self.allocator.free(self.stack);
        if (self.error_message) |err| {
            self.allocator.free(err);
        }
    }
};

/// Execute bytecode using Geth via subprocess
/// Geth can execute bytecode via eth_call JSON-RPC or direct execution
pub fn executeWithGeth(allocator: std.mem.Allocator, bytecode: []const u8, calldata: []const u8) !ReferenceResult {
    // For now, return a placeholder that indicates Geth is not yet integrated
    // TODO: Implement actual Geth subprocess execution
    
    _ = bytecode;
    _ = calldata;
    
        return ReferenceResult{
            .success = false,
            .gas_used = 0,
            .return_data = try allocator.dupe(u8, &[_]u8{}),
            .stack = try allocator.alloc(types.U256, 0),
            .error_message = try allocator.dupe(u8, "Geth interface not yet implemented"),
            .allocator = allocator,
        };
}

/// Execute bytecode using PyEVM via Python subprocess
/// PyEVM can execute bytecode directly via Python script
pub fn executeWithPyEVM(allocator: std.mem.Allocator, bytecode: []const u8, calldata: []const u8) !ReferenceResult {
    // Use the pyevm_executor_v3.py script in validation directory (simplified direct state)
    const script_path = "validation/pyevm_executor_v3.py";
    
    // Format bytecode and calldata as hex
    var bytecode_hex = try std.ArrayList(u8).initCapacity(allocator, bytecode.len * 2);
    defer bytecode_hex.deinit(allocator);
    for (bytecode) |b| {
        try bytecode_hex.writer().print("{x:02}", .{b});
    }
    
    var calldata_hex = try std.ArrayList(u8).initCapacity(allocator, calldata.len * 2);
    defer calldata_hex.deinit(allocator);
    for (calldata) |b| {
        try calldata_hex.writer().print("{x:02}", .{b});
    }
    
    const bytecode_hex_str = try bytecode_hex.toOwnedSlice();
    defer allocator.free(bytecode_hex_str);
    const calldata_hex_str = try calldata_hex.toOwnedSlice();
    defer allocator.free(calldata_hex_str);
    
    // Execute Python script
    const python_args = [_][]const u8{ "python3", script_path, bytecode_hex_str, calldata_hex_str };
    
    const result = try std.process.Child.exec(.{
        .allocator = allocator,
        .argv = &python_args,
        .max_output_bytes = 1024 * 1024, // 1MB
    }) catch |err| {
        // Python or PyEVM not available - return placeholder
        return ReferenceResult{
            .success = false,
            .gas_used = 0,
            .return_data = try allocator.dupe(u8, &[_]u8{}),
            .stack = try allocator.alloc(types.U256, 0),
            .error_message = try std.fmt.allocPrint(allocator, "PyEVM execution failed: {}", .{err}),
            .allocator = allocator,
        };
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    
    // Parse output (format: SUCCESS:gas:return_data_hex:stack_hex)
    if (result.term.Exited != 0) {
        return ReferenceResult{
            .success = false,
            .gas_used = 0,
            .return_data = try allocator.dupe(u8, &[_]u8{}),
            .stack = try allocator.alloc(types.U256, 0),
            .error_message = try allocator.dupe(u8, result.stderr),
            .allocator = allocator,
        };
    }
    
    // Parse JSON result from Python script
    const json_result = std.json.parseFromSlice(
        struct {
            success: bool,
            gas_used: ?u64,
            return_data: ?[]const u8,
            stack: []const u64,
            @"error": ?[]const u8,
        },
        allocator,
        result.stdout,
        .{},
    ) catch |err| {
        return ReferenceResult{
            .success = false,
            .gas_used = 0,
            .return_data = try allocator.dupe(u8, &[_]u8{}),
            .stack = try allocator.alloc(types.U256, 0),
            .error_message = try std.fmt.allocPrint(allocator, "JSON parse error: {}", .{err}),
            .allocator = allocator,
        };
    };
    defer json_result.deinit();
    
    const parsed = json_result.value;
    
    // Parse return data hex
    const return_data_hex = parsed.return_data orelse "0x";
    const return_data = if (std.mem.startsWith(u8, return_data_hex, "0x"))
        try parseHex(allocator, return_data_hex[2..])
    else
        try parseHex(allocator, return_data_hex);
    
    // Parse error if present
    const error_msg = if (parsed.@"error") |err| 
        try allocator.dupe(u8, err)
    else
        null;
    
    return ReferenceResult{
        .success = parsed.success,
        .gas_used = parsed.gas_used orelse 0,
        .return_data = return_data,
        .stack = try allocator.alloc(types.U256, 0), // TODO: Parse stack from JSON
        .error_message = error_msg,
        .allocator = allocator,
    };
}

/// Parse hex string to bytes
fn parseHex(allocator: std.mem.Allocator, hex: []const u8) ![]const u8 {
    if (hex.len % 2 != 0) {
        return error.InvalidHex;
    }
    
    var bytes = try allocator.alloc(u8, hex.len / 2);
    var i: usize = 0;
    while (i < bytes.len) {
        const high = try hexCharToNibble(hex[i * 2]);
        const low = try hexCharToNibble(hex[i * 2 + 1]);
        bytes[i] = (@as(u8, high) << 4) | low;
        i += 1;
    }
    
    return bytes;
}

/// Convert hex character to nibble
fn hexCharToNibble(c: u8) !u4 {
    return switch (c) {
        '0'...'9' => @as(u4, @intCast(c - '0')),
        'a'...'f' => @as(u4, @intCast(c - 'a' + 10)),
        'A'...'F' => @as(u4, @intCast(c - 'A' + 10)),
        else => error.InvalidHexChar,
    };
}

/// Check if Geth is available
pub fn isGethAvailable() bool {
    // Check if geth command is available
    const result = try std.process.Child.exec(.{
        .allocator = std.heap.page_allocator,
        .argv = &.{ "which", "geth" },
        .max_output_bytes = 256,
    }) catch return false;
    defer std.heap.page_allocator.free(result.stdout);
    defer std.heap.page_allocator.free(result.stderr);
    
    return result.term.Exited == 0;
}

/// Check if PyEVM is available
pub fn isPyEVMAvailable() bool {
    // Check if python3 and PyEVM are available, and script exists
    const script_path = "validation/pyevm_executor.py";
    
    // Check if script file exists
    const script_file = std.fs.cwd().openFile(script_path, .{}) catch return false;
    script_file.close();
    
    // Check if PyEVM is importable
    const result = try std.process.Child.exec(.{
        .allocator = std.heap.page_allocator,
        .argv = &.{ "python3", "-c", "import eth; from eth.vm.forks import BerlinVM" },
        .max_output_bytes = 256,
    }) catch return false;
    defer std.heap.page_allocator.free(result.stdout);
    defer std.heap.page_allocator.free(result.stderr);
    
    return result.term.Exited == 0;
}

const testing = std.testing;

test "Reference interfaces: Check availability" {
    const geth_available = isGethAvailable();
    const pyevm_available = isPyEVMAvailable();
    
    std.debug.print("Geth available: {}\n", .{geth_available});
    std.debug.print("PyEVM available: {}\n", .{pyevm_available});
    
    // Test doesn't require either to be available - values are printed above
}

test "Reference interfaces: Hex parsing" {
    const testing_allocator = testing.allocator;
    const hex = "414243";
    const bytes_result = try parseHex(testing_allocator, hex);
    defer testing_allocator.free(bytes_result);
    
    try testing.expectEqual(@as(usize, 3), bytes_result.len);
    try testing.expectEqual(@as(u8, 0x41), bytes_result[0]);
    try testing.expectEqual(@as(u8, 0x42), bytes_result[1]);
    try testing.expectEqual(@as(u8, 0x43), bytes_result[2]);
}

