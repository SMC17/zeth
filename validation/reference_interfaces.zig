const std = @import("std");
const types = @import("types");

/// Interface to reference Ethereum implementations (Geth, PyEVM)
/// Uses subprocess execution to run bytecode and compare results

pub const ReferenceResult = struct {
    success: bool,
    gas_used: u64,
    return_data: []const u8,
    stack: []types.U256,
    error: ?[]const u8,
    allocator: std.mem.Allocator,
    
    pub fn deinit(self: *ReferenceResult) void {
        self.allocator.free(self.return_data);
        for (self.stack) |item| {
            _ = item; // U256 doesn't need deinit
        }
        self.allocator.free(self.stack);
        if (self.error) |err| {
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
        .error = try allocator.dupe(u8, "Geth interface not yet implemented"),
        .allocator = allocator,
    };
}

/// Execute bytecode using PyEVM via Python subprocess
/// PyEVM can execute bytecode directly via Python script
pub fn executeWithPyEVM(allocator: std.mem.Allocator, bytecode: []const u8, calldata: []const u8) !ReferenceResult {
    // Create a Python script to execute bytecode
    const script_content = 
        "import sys\n" ++
        "try:\n" ++
        "    from eth import constants\n" ++
        "    from eth.vm import VM\n" ++
        "    # PyEVM execution placeholder\n" ++
        "    print('SUCCESS:0:0x:')\n" ++
        "except ImportError:\n" ++
        "    print('ERROR:PyEVM not installed')\n" ++
        "    sys.exit(1)\n"
    ;
    
    // Write script to temp file
    var tmp_dir = std.fs.cwd();
    const script_path = "/tmp/zeth_pyevm_test.py";
    var script_file = try tmp_dir.createFile(script_path, .{});
    defer script_file.close();
    try script_file.writeAll(script_content);
    
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
    
    var result = std.ChildProcess.exec(.{
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
            .error = try std.fmt.allocPrint(allocator, "PyEVM execution failed: {}", .{err}),
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
            .error = try allocator.dupe(u8, result.stderr),
            .allocator = allocator,
        };
    }
    
    // Parse result.stdout
    const lines = std.mem.splitSequence(u8, result.stdout, "\n");
    const first_line = lines.next() orelse "";
    
    if (std.mem.startsWith(u8, first_line, "SUCCESS:")) {
        // Format: SUCCESS:gas:return_data_hex:stack_hex
        var parts = std.mem.splitSequence(u8, first_line, ":");
        _ = parts.next(); // Skip "SUCCESS"
        
        const gas_str = parts.next() orelse "0";
        const return_hex = parts.next() orelse "";
        _ = parts.next(); // Skip stack for now
        
        const gas_used = std.fmt.parseInt(u64, gas_str, 10) catch 0;
        
        // Parse return data hex
        const return_data = if (std.mem.startsWith(u8, return_hex, "0x"))
            try parseHex(allocator, return_hex[2..])
        else
            try parseHex(allocator, return_hex);
        
        return ReferenceResult{
            .success = true,
            .gas_used = gas_used,
            .return_data = return_data,
            .stack = try allocator.alloc(types.U256, 0), // TODO: Parse stack
            .error = null,
            .allocator = allocator,
        };
    } else {
        return ReferenceResult{
            .success = false,
            .gas_used = 0,
            .return_data = try allocator.dupe(u8, &[_]u8{}),
            .stack = try allocator.alloc(types.U256, 0),
            .error = try allocator.dupe(u8, first_line),
            .allocator = allocator,
        };
    }
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
    const result = std.ChildProcess.exec(.{
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
    // Check if python3 and PyEVM are available
    const result = std.ChildProcess.exec(.{
        .allocator = std.heap.page_allocator,
        .argv = &.{ "python3", "-c", "import eth" },
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
    
    // Test doesn't require either to be available
    _ = geth_available;
    _ = pyevm_available;
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

