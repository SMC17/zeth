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
    // Use the pyevm_executor_simple.py script in validation directory
    // Note: PyEVM API integration is complex - using placeholder for now
    const script_path = "validation/pyevm_executor_simple.py";
    
    // Format bytecode and calldata as hex
    var bytecode_hex = try std.ArrayList(u8).initCapacity(allocator, bytecode.len * 2);
    defer bytecode_hex.deinit(allocator);
    var writer = bytecode_hex.writer(allocator);
    for (bytecode) |b| {
        try writer.print("{x:02}", .{b});
    }
    
    var calldata_hex = try std.ArrayList(u8).initCapacity(allocator, calldata.len * 2);
    defer calldata_hex.deinit(allocator);
    var calldata_writer = calldata_hex.writer(allocator);
    for (calldata) |b| {
        try calldata_writer.print("{x:02}", .{b});
    }
    
    const bytecode_hex_str = try bytecode_hex.toOwnedSlice(allocator);
    defer allocator.free(bytecode_hex_str);
    const calldata_hex_str = try calldata_hex.toOwnedSlice(allocator);
    defer allocator.free(calldata_hex_str);
    
    // Execute Python script using spawn and read output
    var child = std.process.Child.init(&.{ "python3", script_path, bytecode_hex_str, calldata_hex_str }, allocator);
    child.stdin_behavior = .Close;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    
    child.spawn() catch |err| {
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
    
    // Wait for process to complete first
    const term = child.wait() catch |err| {
        return ReferenceResult{
            .success = false,
            .gas_used = 0,
            .return_data = try allocator.dupe(u8, &[_]u8{}),
            .stack = try allocator.alloc(types.U256, 0),
            .error_message = try std.fmt.allocPrint(allocator, "Failed to wait for process: {}", .{err}),
            .allocator = allocator,
        };
    };
    
    // Read stdout and stderr after process completes
    var stdout_list = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer stdout_list.deinit(allocator);
    var stderr_list = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer stderr_list.deinit(allocator);
    
    if (child.stdout) |stdout_file| {
        var buf: [4096]u8 = undefined;
        var reader = stdout_file.reader(&buf);
        while (true) {
            const bytes_read = reader.read(&buf) catch |err| {
                if (err == error.EndOfStream) break;
                return ReferenceResult{
                    .success = false,
                    .gas_used = 0,
                    .return_data = try allocator.dupe(u8, &[_]u8{}),
                    .stack = try allocator.alloc(types.U256, 0),
                    .error_message = try std.fmt.allocPrint(allocator, "Failed to read stdout: {}", .{err}),
                    .allocator = allocator,
                };
            };
            if (bytes_read == 0) break;
            try stdout_list.appendSlice(allocator, buf[0..bytes_read]);
        }
    }
    
    if (child.stderr) |stderr_file| {
        var buf: [4096]u8 = undefined;
        var reader = stderr_file.reader(&buf);
        while (true) {
            const bytes_read = reader.read(&buf) catch |err| {
                if (err == error.EndOfStream) break;
                return ReferenceResult{
                    .success = false,
                    .gas_used = 0,
                    .return_data = try allocator.dupe(u8, &[_]u8{}),
                    .stack = try allocator.alloc(types.U256, 0),
                    .error_message = try std.fmt.allocPrint(allocator, "Failed to read stderr: {}", .{err}),
                    .allocator = allocator,
                };
            };
            if (bytes_read == 0) break;
            try stderr_list.appendSlice(allocator, buf[0..bytes_read]);
        }
    }
    
    const stdout = try stdout_list.toOwnedSlice(allocator);
    defer allocator.free(stdout);
    const stderr = try stderr_list.toOwnedSlice(allocator);
    defer allocator.free(stderr);
    
    const result = struct {
        stdout: []const u8,
        stderr: []const u8,
        term: std.process.Child.Term,
    }{
        .stdout = stdout,
        .stderr = stderr,
        .term = term,
    };
    
    // Parse output (format: SUCCESS:gas:return_data_hex:stack_hex)
    if (result.term != .Exited or result.term.Exited != 0) {
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
    var child = std.process.Child.init(&.{ "which", "geth" }, std.heap.page_allocator);
    child.stdin_behavior = .Close;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    
    child.spawn() catch return false;
    
    const term = child.wait() catch return false;
    
    // Drain stdout/stderr
    if (child.stdout) |stdout_file| {
        var buf: [256]u8 = undefined;
        var reader = stdout_file.reader(&buf);
        while (true) {
            const bytes_read = reader.read(&buf) catch break;
            if (bytes_read == 0) break;
        }
    }
    if (child.stderr) |stderr_file| {
        var buf: [256]u8 = undefined;
        var reader = stderr_file.reader(&buf);
        while (true) {
            const bytes_read = reader.read(&buf) catch break;
            if (bytes_read == 0) break;
        }
    }
    
    return term == .Exited and term.Exited == 0;
}

/// Check if PyEVM is available
pub fn isPyEVMAvailable() bool {
    // Check if python3 and PyEVM are available, and script exists
    const script_path = "validation/pyevm_executor_v3.py";
    
    // Check if script file exists
    const script_file = std.fs.cwd().openFile(script_path, .{}) catch return false;
    script_file.close();
    
    // Check if PyEVM is importable
    var child = std.process.Child.init(&.{ "python3", "-c", "import eth; from eth.vm.forks import BerlinVM" }, std.heap.page_allocator);
    child.stdin_behavior = .Close;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    
    child.spawn() catch return false;
    
    const term = child.wait() catch return false;
    
    // Drain stdout/stderr
    if (child.stdout) |stdout_file| {
        var buf: [256]u8 = undefined;
        var reader = stdout_file.reader(&buf);
        while (true) {
            const bytes_read = reader.read(&buf) catch break;
            if (bytes_read == 0) break;
        }
    }
    if (child.stderr) |stderr_file| {
        var buf: [256]u8 = undefined;
        var reader = stderr_file.reader(&buf);
        while (true) {
            const bytes_read = reader.read(&buf) catch break;
            if (bytes_read == 0) break;
        }
    }
    
    return term == .Exited and term.Exited == 0;
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

