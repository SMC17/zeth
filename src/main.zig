const std = @import("std");
const types = @import("types");
const crypto = @import("crypto");
const rlp = @import("rlp");
const evm = @import("evm");
const state = @import("state");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Zeth - Ethereum Implementation in Zig\n", .{});
    std.debug.print("======================================\n\n", .{});
    
    // Example: Create and hash a simple transaction
    const tx = types.Transaction{
        .nonce = 0,
        .gas_price = 20000000000,
        .gas_limit = 21000,
        .to = null,
        .value = 1000000000000000000,
        .data = &.{},
        .v = 0,
        .r = types.U256.zero(),
        .s = types.U256.zero(),
    };

    std.debug.print("Transaction created:\n", .{});
    std.debug.print("  Nonce: {}\n", .{tx.nonce});
    std.debug.print("  Gas Price: {}\n", .{tx.gas_price});
    std.debug.print("  Gas Limit: {}\n", .{tx.gas_limit});
    std.debug.print("  Value: {} wei\n", .{tx.value});
    
    // Example: Hash computation
    const data = "Hello, Ethereum!";
    var hash: [32]u8 = undefined;
    crypto.keccak256(data, &hash);
    
    std.debug.print("\nKeccak256 hash of \"{s}\":\n", .{data});
    std.debug.print("  0x", .{});
    for (hash) |byte| {
        std.debug.print("{x:0>2}", .{byte});
    }
    std.debug.print("\n", .{});

    _ = allocator;
}

test "basic functionality" {
    const testing = std.testing;
    
    // Test that we can import all modules
    _ = types;
    _ = crypto;
    _ = rlp;
    _ = evm;
    _ = state;
    
    try testing.expect(true);
}

