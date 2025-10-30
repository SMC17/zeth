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
    
    pub fn format(self: Discrepancy, writer: anytype, allocator: std.mem.Allocator) !void {
        const opcode_str = try std.fmt.allocPrint(allocator, "Discrepancy: {s}\n", .{self.opcode});
        defer allocator.free(opcode_str);
        try writer.writeAll(opcode_str);
        
        const type_str = try std.fmt.allocPrint(allocator, "  Type: {s}\n", .{@tagName(self.type)});
        defer allocator.free(type_str);
        try writer.writeAll(type_str);
        
        const severity_str = try std.fmt.allocPrint(allocator, "  Severity: {s}\n", .{@tagName(self.severity)});
        defer allocator.free(severity_str);
        try writer.writeAll(severity_str);
        
        const desc_str = try std.fmt.allocPrint(allocator, "  Description: {s}\n", .{self.description});
        defer allocator.free(desc_str);
        try writer.writeAll(desc_str);
        
        const our_val_str = try std.fmt.allocPrint(allocator, "  Our value: {s}\n", .{self.our_value});
        defer allocator.free(our_val_str);
        try writer.writeAll(our_val_str);
        
        const ref_val_str = try std.fmt.allocPrint(allocator, "  Reference: {s}\n", .{self.reference_value});
        defer allocator.free(ref_val_str);
        try writer.writeAll(ref_val_str);
        
        const fixed_str = try std.fmt.allocPrint(allocator, "  Fixed: {}\n", .{self.fixed});
        defer allocator.free(fixed_str);
        try writer.writeAll(fixed_str);
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
    
    pub fn formatReport(self: *const DiscrepancyTracker, writer: anytype) !void {
        try writer.writeAll("Discrepancy Report\n");
        try writer.writeAll("==================\n\n");
        
        const total = try std.fmt.allocPrint(self.allocator, "Total discrepancies: {}\n", .{self.count()});
        defer self.allocator.free(total);
        try writer.writeAll(total);
        
        const critical = try std.fmt.allocPrint(self.allocator, "  Critical: {}\n", .{self.countBySeverity(.critical)});
        defer self.allocator.free(critical);
        try writer.writeAll(critical);
        
        const high = try std.fmt.allocPrint(self.allocator, "  High: {}\n", .{self.countBySeverity(.high)});
        defer self.allocator.free(high);
        try writer.writeAll(high);
        
        const medium = try std.fmt.allocPrint(self.allocator, "  Medium: {}\n", .{self.countBySeverity(.medium)});
        defer self.allocator.free(medium);
        try writer.writeAll(medium);
        
        const low = try std.fmt.allocPrint(self.allocator, "  Low: {}\n", .{self.countBySeverity(.low)});
        defer self.allocator.free(low);
        try writer.writeAll(low);
        
        try writer.writeAll("\n");
        try writer.writeAll("By type:\n");
        
        inline for (@typeInfo(DiscrepancyType).Enum.fields) |field| {
            const disc_type = @field(DiscrepancyType, field.name);
            const type_str = try std.fmt.allocPrint(self.allocator, "  {s}: {}\n", .{ field.name, self.countByType(disc_type) });
            defer self.allocator.free(type_str);
            try writer.writeAll(type_str);
        }
        try writer.writeAll("\n");
        
        for (self.discrepancies.items) |disc| {
            try disc.format(writer, self.allocator);
            try writer.writeAll("\n");
        }
    }
    
    pub fn saveToFile(self: *const DiscrepancyTracker, file_path: []const u8) !void {
        var file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();
        
        var buf: [4096]u8 = undefined;
        const writer = file.writer(&buf);
        try self.formatReport(writer);
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

