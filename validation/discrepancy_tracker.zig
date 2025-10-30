const std = @import("std");
const types = @import("types");

/// Track and document discrepancies between our implementation and reference

pub const DiscrepancyType = enum {
    gas_cost,
    stack_state,
    memory_state,
    storage_state,
    execution_result,
    error_handling,
    return_data,
    other,
};

pub const Discrepancy = struct {
    opcode: []const u8,
    type: DiscrepancyType,
    description: []const u8,
    our_value: []const u8,
    reference_value: []const u8,
    bytecode: []const u8,
    calldata: []const u8,
    severity: Severity,
    fixed: bool = false,
    
    pub const Severity = enum {
        critical,   // Breaks contract execution
        high,       // Causes incorrect results
        medium,     // Gas cost differences
        low,        // Minor differences
    };
    
    pub fn format(self: Discrepancy, writer: anytype) !void {
        try writer.print("Discrepancy: {s}\n", .{self.opcode});
        try writer.print("  Type: {s}\n", .{@tagName(self.type)});
        try writer.print("  Severity: {s}\n", .{@tagName(self.severity)});
        try writer.print("  Description: {s}\n", .{self.description});
        try writer.print("  Our value: {s}\n", .{self.our_value});
        try writer.print("  Reference: {s}\n", .{self.reference_value});
        try writer.print("  Fixed: {}\n", .{self.fixed});
    }
};

pub const DiscrepancyTracker = struct {
    discrepancies: std.ArrayList(Discrepancy),
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) !DiscrepancyTracker {
        return DiscrepancyTracker{
            .discrepancies = try std.ArrayList(Discrepancy).initCapacity(allocator, 0),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *DiscrepancyTracker) void {
        for (self.discrepancies.items) |*disc| {
            self.allocator.free(disc.description);
            self.allocator.free(disc.our_value);
            self.allocator.free(disc.reference_value);
            self.allocator.free(disc.bytecode);
            self.allocator.free(disc.calldata);
        }
        self.discrepancies.deinit(self.allocator);
    }
    
    pub fn add(self: *DiscrepancyTracker, opcode: []const u8, disc_type: DiscrepancyType, description: []const u8, our_val: []const u8, ref_val: []const u8, bytecode: []const u8, calldata: []const u8, severity: Discrepancy.Severity) !void {
        try self.discrepancies.append(self.allocator, Discrepancy{
            .opcode = opcode,
            .type = disc_type,
            .description = try self.allocator.dupe(u8, description),
            .our_value = try self.allocator.dupe(u8, our_val),
            .reference_value = try self.allocator.dupe(u8, ref_val),
            .bytecode = try self.allocator.dupe(u8, bytecode),
            .calldata = try self.allocator.dupe(u8, calldata),
            .severity = severity,
            .fixed = false,
        });
    }
    
    pub fn count(self: *const DiscrepancyTracker) usize {
        return self.discrepancies.items.len;
    }
    
    pub fn countBySeverity(self: *const DiscrepancyTracker, severity: Discrepancy.Severity) usize {
        var counter: usize = 0;
        for (self.discrepancies.items) |disc| {
            if (disc.severity == severity) {
                counter += 1;
            }
        }
        return counter;
    }
    
    pub fn countByType(self: *const DiscrepancyTracker, disc_type: DiscrepancyType) usize {
        var counter: usize = 0;
        for (self.discrepancies.items) |disc| {
            if (disc.type == disc_type) {
                counter += 1;
            }
        }
        return counter;
    }
    
    // Helper formatReport that works with ArrayList writer (which has print method)
    fn formatReport(self: *const DiscrepancyTracker, writer: anytype) !void {
        try writer.print("Discrepancy Report\n", .{});
        try writer.print("==================\n\n", .{});
        try writer.print("Total discrepancies: {}\n", .{self.count()});
        try writer.print("  Critical: {}\n", .{self.countBySeverity(.critical)});
        try writer.print("  High: {}\n", .{self.countBySeverity(.high)});
        try writer.print("  Medium: {}\n", .{self.countBySeverity(.medium)});
        try writer.print("  Low: {}\n", .{self.countBySeverity(.low)});
        try writer.print("\n", .{});
        
        try writer.print("By type:\n", .{});
        // Manually iterate enum values
        try writer.print("  gas_cost: {}\n", .{self.countByType(.gas_cost)});
        try writer.print("  stack_state: {}\n", .{self.countByType(.stack_state)});
        try writer.print("  memory_state: {}\n", .{self.countByType(.memory_state)});
        try writer.print("  storage_state: {}\n", .{self.countByType(.storage_state)});
        try writer.print("  execution_result: {}\n", .{self.countByType(.execution_result)});
        try writer.print("\n", .{});
        
        for (self.discrepancies.items) |disc| {
            try disc.format(writer);
            try writer.print("\n", .{});
        }
    }
    
    pub fn saveToFile(self: *const DiscrepancyTracker, file_path: []const u8) !void {
        var file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();
        
        // Build report string in memory, then write to file
        var report_list = try std.ArrayList(u8).initCapacity(self.allocator, 4096);
        defer report_list.deinit(self.allocator);
        
        const writer = report_list.writer(self.allocator);
        try self.formatReport(writer);
        
        const report = try report_list.toOwnedSlice(self.allocator);
        defer self.allocator.free(report);
        
        _ = try file.write(report);
    }
};

const testing = std.testing;

test "Discrepancy tracker: Basic operations" {
    const testing_allocator = testing.allocator;
    var tracker = try DiscrepancyTracker.init(testing_allocator);
    defer tracker.deinit();
    
    try tracker.add("ADD", .gas_cost, "Gas cost differs", "9", "10", &[_]u8{0x01}, &[_]u8{}, .medium);
    
    try testing.expectEqual(@as(usize, 1), tracker.count());
    try testing.expectEqual(@as(usize, 1), tracker.countByType(.gas_cost));
    try testing.expectEqual(@as(usize, 1), tracker.countBySeverity(.medium));
}

