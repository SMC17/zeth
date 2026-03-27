//! zeth JSON-RPC server — Ethereum execution API (EIP-1474 subset).
//!
//! Pure request/response handler: takes a JSON-RPC string, returns a JSON-RPC
//! string.  No HTTP, no sockets — the transport layer is plugged in separately.
//!
//! Supported methods:
//!   eth_call, eth_estimateGas, eth_chainId, eth_blockNumber,
//!   eth_getBalance, eth_getCode, eth_getStorageAt

const std = @import("std");
const sim = @import("sim");
const types = @import("types");
const state = @import("state");

pub const Address = types.Address;
pub const U256 = types.U256;

// ---------------------------------------------------------------------------
// JSON-RPC error codes (subset of EIP-1474)
// ---------------------------------------------------------------------------
const PARSE_ERROR: i64 = -32700;
const INVALID_REQUEST: i64 = -32600;
const METHOD_NOT_FOUND: i64 = -32601;
const INVALID_PARAMS: i64 = -32602;
const INTERNAL_ERROR: i64 = -32603;
const EXECUTION_ERROR: i64 = 3; // Geth-style revert code

// ---------------------------------------------------------------------------
// Hex utilities
// ---------------------------------------------------------------------------

const hex_chars = "0123456789abcdef";

/// Encode arbitrary bytes as a 0x-prefixed hex string.
pub fn hexEncode(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    if (bytes.len == 0) {
        const out = try allocator.alloc(u8, 3);
        out[0] = '0';
        out[1] = 'x';
        out[2] = '0';
        return out;
    }
    const out = try allocator.alloc(u8, 2 + bytes.len * 2);
    out[0] = '0';
    out[1] = 'x';
    for (bytes, 0..) |b, i| {
        out[2 + i * 2] = hex_chars[b >> 4];
        out[2 + i * 2 + 1] = hex_chars[b & 0x0f];
    }
    return out;
}

/// Encode a u64 as a minimal 0x-prefixed hex string (no leading zeros except "0x0").
pub fn hexEncodeU64(allocator: std.mem.Allocator, value: u64) ![]u8 {
    if (value == 0) {
        const out = try allocator.alloc(u8, 3);
        out[0] = '0';
        out[1] = 'x';
        out[2] = '0';
        return out;
    }
    // Count hex digits needed
    var tmp = value;
    var digits: usize = 0;
    while (tmp > 0) : (tmp >>= 4) {
        digits += 1;
    }
    const out = try allocator.alloc(u8, 2 + digits);
    out[0] = '0';
    out[1] = 'x';
    tmp = value;
    var i: usize = digits;
    while (i > 0) {
        i -= 1;
        out[2 + i] = hex_chars[@intCast(tmp & 0x0f)];
        tmp >>= 4;
    }
    return out;
}

/// Encode a U256 as a minimal 0x-prefixed hex string.
pub fn hexEncodeU256(allocator: std.mem.Allocator, value: U256) ![]u8 {
    const bytes = value.toBytes(); // big-endian [32]u8
    // Skip leading zeros
    var start: usize = 0;
    while (start < 32 and bytes[start] == 0) : (start += 1) {}
    if (start == 32) {
        const out = try allocator.alloc(u8, 3);
        out[0] = '0';
        out[1] = 'x';
        out[2] = '0';
        return out;
    }
    const significant = bytes[start..];
    const out = try allocator.alloc(u8, 2 + significant.len * 2);
    out[0] = '0';
    out[1] = 'x';
    for (significant, 0..) |b, i| {
        out[2 + i * 2] = hex_chars[b >> 4];
        out[2 + i * 2 + 1] = hex_chars[b & 0x0f];
    }
    return out;
}

/// Decode a 0x-prefixed hex string to bytes.
pub fn hexDecode(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
    const start: usize = if (hex.len >= 2 and hex[0] == '0' and (hex[1] == 'x' or hex[1] == 'X')) 2 else 0;
    const payload = hex[start..];
    if (payload.len == 0) {
        return try allocator.alloc(u8, 0);
    }
    // Handle odd-length hex by treating it as 0-prefixed
    const padded_len = payload.len + (payload.len & 1);
    const out_len = padded_len / 2;
    const out = try allocator.alloc(u8, out_len);
    var src_idx: usize = 0;
    var dst_idx: usize = 0;
    // If odd length, first nibble is high nibble of first byte with implicit 0
    if (payload.len & 1 == 1) {
        out[0] = try hexNibble(payload[0]);
        src_idx = 1;
        dst_idx = 1;
    }
    while (src_idx < payload.len) : ({
        src_idx += 2;
        dst_idx += 1;
    }) {
        const hi = try hexNibble(payload[src_idx]);
        const lo = try hexNibble(payload[src_idx + 1]);
        out[dst_idx] = (@as(u8, hi) << 4) | @as(u8, lo);
    }
    return out;
}

fn hexNibble(c: u8) !u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'f' => @intCast(c - 'a' + 10),
        'A'...'F' => @intCast(c - 'A' + 10),
        else => error.InvalidHexCharacter,
    };
}

/// Parse a hex string to a U256.
fn hexToU256(hex: []const u8) !U256 {
    const start: usize = if (hex.len >= 2 and hex[0] == '0' and (hex[1] == 'x' or hex[1] == 'X')) 2 else 0;
    const payload = hex[start..];
    if (payload.len == 0) return U256.zero();
    if (payload.len > 64) return error.InvalidParams;

    // Pad to 64 hex chars, then convert to 32 bytes
    var buf: [32]u8 = [_]u8{0} ** 32;
    const byte_count = (payload.len + 1) / 2;
    const byte_start = 32 - byte_count;

    var src: usize = 0;
    var dst: usize = byte_start;
    // Odd length: first nibble stands alone
    if (payload.len & 1 == 1) {
        buf[dst] = hexNibble(payload[0]) catch return error.InvalidParams;
        src = 1;
        dst += 1;
    }
    while (src < payload.len) : ({
        src += 2;
        dst += 1;
    }) {
        const hi = hexNibble(payload[src]) catch return error.InvalidParams;
        const lo = hexNibble(payload[src + 1]) catch return error.InvalidParams;
        buf[dst] = (@as(u8, hi) << 4) | @as(u8, lo);
    }
    return U256.fromBytes(buf);
}

/// Parse a hex string to a u64.
fn hexToU64(hex: []const u8) !u64 {
    const start: usize = if (hex.len >= 2 and hex[0] == '0' and (hex[1] == 'x' or hex[1] == 'X')) 2 else 0;
    const payload = hex[start..];
    if (payload.len == 0) return 0;
    if (payload.len > 16) return error.InvalidParams;

    var result: u64 = 0;
    for (payload) |c| {
        const nib: u64 = @intCast(hexNibble(c) catch return error.InvalidParams);
        result = (result << 4) | nib;
    }
    return result;
}

/// Parse a hex string to a 20-byte Address.
fn hexToAddress(hex: []const u8) !Address {
    const start: usize = if (hex.len >= 2 and hex[0] == '0' and (hex[1] == 'x' or hex[1] == 'X')) 2 else 0;
    const payload = hex[start..];
    if (payload.len != 40) return error.InvalidParams;

    var bytes: [20]u8 = undefined;
    for (0..20) |i| {
        const hi = hexNibble(payload[i * 2]) catch return error.InvalidParams;
        const lo = hexNibble(payload[i * 2 + 1]) catch return error.InvalidParams;
        bytes[i] = (@as(u8, hi) << 4) | @as(u8, lo);
    }
    return Address{ .bytes = bytes };
}

// ---------------------------------------------------------------------------
// RPC Server
// ---------------------------------------------------------------------------

pub const RpcServer = struct {
    allocator: std.mem.Allocator,
    state_db: *state.StateDB,
    chain_id: u64,
    block_number: u64,

    /// Process a JSON-RPC request string and return a JSON-RPC response string.
    /// Caller owns the returned slice.
    pub fn handleRequest(self: *RpcServer, json_request: []const u8) ![]u8 {
        // Parse the incoming JSON
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, json_request, .{}) catch {
            return self.formatError(null, PARSE_ERROR, "Parse error");
        };
        defer parsed.deinit();
        const root = parsed.value;

        // Extract id (may be number, string, or null)
        const id = root.object.get("id");

        // Validate jsonrpc field
        const jsonrpc = root.object.get("jsonrpc") orelse {
            return self.formatError(id, INVALID_REQUEST, "Missing jsonrpc field");
        };
        switch (jsonrpc) {
            .string => |s| {
                if (!std.mem.eql(u8, s, "2.0")) {
                    return self.formatError(id, INVALID_REQUEST, "jsonrpc must be \"2.0\"");
                }
            },
            else => return self.formatError(id, INVALID_REQUEST, "jsonrpc must be a string"),
        }

        // Extract method
        const method_val = root.object.get("method") orelse {
            return self.formatError(id, INVALID_REQUEST, "Missing method field");
        };
        const method = switch (method_val) {
            .string => |s| s,
            else => return self.formatError(id, INVALID_REQUEST, "method must be a string"),
        };

        // Extract params (optional — default to empty array)
        const params = root.object.get("params");

        // Dispatch
        return self.dispatch(id, method, params);
    }

    fn dispatch(self: *RpcServer, id: ?std.json.Value, method: []const u8, params: ?std.json.Value) ![]u8 {
        if (std.mem.eql(u8, method, "eth_chainId")) {
            return self.ethChainId(id);
        } else if (std.mem.eql(u8, method, "eth_blockNumber")) {
            return self.ethBlockNumber(id);
        } else if (std.mem.eql(u8, method, "eth_getBalance")) {
            return self.ethGetBalance(id, params);
        } else if (std.mem.eql(u8, method, "eth_getCode")) {
            return self.ethGetCode(id, params);
        } else if (std.mem.eql(u8, method, "eth_getStorageAt")) {
            return self.ethGetStorageAt(id, params);
        } else if (std.mem.eql(u8, method, "eth_call")) {
            return self.ethCall(id, params);
        } else if (std.mem.eql(u8, method, "eth_estimateGas")) {
            return self.ethEstimateGas(id, params);
        } else {
            return self.formatError(id, METHOD_NOT_FOUND, "Method not found");
        }
    }

    // -----------------------------------------------------------------------
    // eth_chainId
    // -----------------------------------------------------------------------
    fn ethChainId(self: *RpcServer, id: ?std.json.Value) ![]u8 {
        const hex = try hexEncodeU64(self.allocator, self.chain_id);
        defer self.allocator.free(hex);
        return self.formatResult(id, hex);
    }

    // -----------------------------------------------------------------------
    // eth_blockNumber
    // -----------------------------------------------------------------------
    fn ethBlockNumber(self: *RpcServer, id: ?std.json.Value) ![]u8 {
        const hex = try hexEncodeU64(self.allocator, self.block_number);
        defer self.allocator.free(hex);
        return self.formatResult(id, hex);
    }

    // -----------------------------------------------------------------------
    // eth_getBalance
    // -----------------------------------------------------------------------
    fn ethGetBalance(self: *RpcServer, id: ?std.json.Value, params: ?std.json.Value) ![]u8 {
        const arr = self.expectParamsArray(params, 1) orelse {
            return self.formatError(id, INVALID_PARAMS, "Expected [address, blockNumber]");
        };

        const addr_str = switch (arr[0]) {
            .string => |s| s,
            else => return self.formatError(id, INVALID_PARAMS, "address must be hex string"),
        };

        const addr = hexToAddress(addr_str) catch {
            return self.formatError(id, INVALID_PARAMS, "Invalid address");
        };

        const balance = self.state_db.getBalance(addr) catch {
            return self.formatError(id, INTERNAL_ERROR, "State lookup failed");
        };

        const hex = try hexEncodeU256(self.allocator, balance);
        defer self.allocator.free(hex);
        return self.formatResult(id, hex);
    }

    // -----------------------------------------------------------------------
    // eth_getCode
    // -----------------------------------------------------------------------
    fn ethGetCode(self: *RpcServer, id: ?std.json.Value, params: ?std.json.Value) ![]u8 {
        const arr = self.expectParamsArray(params, 1) orelse {
            return self.formatError(id, INVALID_PARAMS, "Expected [address, blockNumber]");
        };

        const addr_str = switch (arr[0]) {
            .string => |s| s,
            else => return self.formatError(id, INVALID_PARAMS, "address must be hex string"),
        };

        const addr = hexToAddress(addr_str) catch {
            return self.formatError(id, INVALID_PARAMS, "Invalid address");
        };

        const code = self.state_db.getCode(addr);
        const hex = try hexEncode(self.allocator, code);
        defer self.allocator.free(hex);
        return self.formatResult(id, hex);
    }

    // -----------------------------------------------------------------------
    // eth_getStorageAt
    // -----------------------------------------------------------------------
    fn ethGetStorageAt(self: *RpcServer, id: ?std.json.Value, params: ?std.json.Value) ![]u8 {
        const arr = self.expectParamsArray(params, 2) orelse {
            return self.formatError(id, INVALID_PARAMS, "Expected [address, position, blockNumber]");
        };

        const addr_str = switch (arr[0]) {
            .string => |s| s,
            else => return self.formatError(id, INVALID_PARAMS, "address must be hex string"),
        };
        const pos_str = switch (arr[1]) {
            .string => |s| s,
            else => return self.formatError(id, INVALID_PARAMS, "position must be hex string"),
        };

        const addr = hexToAddress(addr_str) catch {
            return self.formatError(id, INVALID_PARAMS, "Invalid address");
        };
        const pos = hexToU256(pos_str) catch {
            return self.formatError(id, INVALID_PARAMS, "Invalid storage position");
        };

        const value = self.state_db.getStorage(addr, pos) catch {
            return self.formatError(id, INTERNAL_ERROR, "State lookup failed");
        };

        // eth_getStorageAt always returns 32 bytes, zero-padded
        const bytes = value.toBytes();
        const hex = try hexEncode(self.allocator, &bytes);
        defer self.allocator.free(hex);
        return self.formatResult(id, hex);
    }

    // -----------------------------------------------------------------------
    // eth_call
    // -----------------------------------------------------------------------
    fn ethCall(self: *RpcServer, id: ?std.json.Value, params: ?std.json.Value) ![]u8 {
        const arr = self.expectParamsArray(params, 1) orelse {
            return self.formatError(id, INVALID_PARAMS, "Expected [{...}, blockNumber]");
        };

        const tx_obj = switch (arr[0]) {
            .object => |o| o,
            else => return self.formatError(id, INVALID_PARAMS, "First param must be object"),
        };

        var req = sim.ExecutionRequest.default();
        req.chain_id = self.chain_id;
        req.block_number = self.block_number;

        // Parse 'from'
        if (tx_obj.get("from")) |v| {
            switch (v) {
                .string => |s| {
                    req.caller = hexToAddress(s) catch {
                        return self.formatError(id, INVALID_PARAMS, "Invalid from address");
                    };
                    req.origin = req.caller;
                },
                else => {},
            }
        }
        // Parse 'to'
        if (tx_obj.get("to")) |v| {
            switch (v) {
                .string => |s| {
                    req.address = hexToAddress(s) catch {
                        return self.formatError(id, INVALID_PARAMS, "Invalid to address");
                    };
                },
                else => {},
            }
        }
        // Parse 'gas'
        if (tx_obj.get("gas")) |v| {
            switch (v) {
                .string => |s| {
                    req.gas_limit = hexToU64(s) catch 30_000_000;
                },
                else => {},
            }
        }
        // Parse 'value'
        if (tx_obj.get("value")) |v| {
            switch (v) {
                .string => |s| {
                    req.value = hexToU256(s) catch U256.zero();
                },
                else => {},
            }
        }

        // Parse 'data' / 'input' (calldata)
        var calldata: []u8 = &[_]u8{};
        var calldata_allocated = false;
        if (tx_obj.get("data") orelse tx_obj.get("input")) |v| {
            switch (v) {
                .string => |s| {
                    calldata = hexDecode(self.allocator, s) catch &[_]u8{};
                    if (calldata.len > 0) calldata_allocated = true;
                },
                else => {},
            }
        }
        defer if (calldata_allocated) self.allocator.free(calldata);

        // Get contract code from state
        const code = self.state_db.getCode(req.address);

        // Execute
        var result = sim.executeWithState(
            self.allocator,
            code,
            calldata,
            req,
            self.state_db,
        ) catch {
            return self.formatError(id, EXECUTION_ERROR, "EVM execution failed");
        };
        defer result.deinit();

        if (!result.success) {
            return self.formatError(id, EXECUTION_ERROR, "execution reverted");
        }

        const hex = try hexEncode(self.allocator, result.return_data);
        defer self.allocator.free(hex);
        return self.formatResult(id, hex);
    }

    // -----------------------------------------------------------------------
    // eth_estimateGas
    // -----------------------------------------------------------------------
    fn ethEstimateGas(self: *RpcServer, id: ?std.json.Value, params: ?std.json.Value) ![]u8 {
        const arr = self.expectParamsArray(params, 1) orelse {
            return self.formatError(id, INVALID_PARAMS, "Expected [{...}]");
        };

        const tx_obj = switch (arr[0]) {
            .object => |o| o,
            else => return self.formatError(id, INVALID_PARAMS, "First param must be object"),
        };

        var req = sim.ExecutionRequest.default();
        req.chain_id = self.chain_id;
        req.block_number = self.block_number;

        // Parse 'from'
        if (tx_obj.get("from")) |v| {
            switch (v) {
                .string => |s| {
                    req.caller = hexToAddress(s) catch Address.zero;
                    req.origin = req.caller;
                },
                else => {},
            }
        }
        // Parse 'to'
        var has_to = false;
        if (tx_obj.get("to")) |v| {
            switch (v) {
                .string => |s| {
                    req.address = hexToAddress(s) catch Address.zero;
                    has_to = true;
                },
                else => {},
            }
        }
        // Parse 'value'
        if (tx_obj.get("value")) |v| {
            switch (v) {
                .string => |s| {
                    req.value = hexToU256(s) catch U256.zero();
                },
                else => {},
            }
        }

        // Parse 'data' / 'input'
        var calldata: []u8 = &[_]u8{};
        var calldata_allocated = false;
        if (tx_obj.get("data") orelse tx_obj.get("input")) |v| {
            switch (v) {
                .string => |s| {
                    calldata = hexDecode(self.allocator, s) catch &[_]u8{};
                    if (calldata.len > 0) calldata_allocated = true;
                },
                else => {},
            }
        }
        defer if (calldata_allocated) self.allocator.free(calldata);

        // Simple transfer (no code, no data) — intrinsic gas is 21000
        const code = self.state_db.getCode(req.address);
        if (code.len == 0 and calldata.len == 0 and has_to) {
            const hex = try hexEncodeU64(self.allocator, 21000);
            defer self.allocator.free(hex);
            return self.formatResult(id, hex);
        }

        // Binary search between lo and hi
        const BLOCK_GAS_LIMIT: u64 = 30_000_000;
        var lo: u64 = 21000;
        var hi: u64 = BLOCK_GAS_LIMIT;

        // First check if hi succeeds at all
        req.gas_limit = hi;
        var result_hi = sim.executeWithState(self.allocator, code, calldata, req, self.state_db) catch {
            return self.formatError(id, EXECUTION_ERROR, "EVM execution failed");
        };
        const hi_success = result_hi.success;
        result_hi.deinit();
        if (!hi_success) {
            return self.formatError(id, EXECUTION_ERROR, "execution reverted");
        }

        // Binary search
        while (lo + 1 < hi) {
            const mid = lo + (hi - lo) / 2;
            req.gas_limit = mid;
            var result_mid = sim.executeWithState(self.allocator, code, calldata, req, self.state_db) catch {
                lo = mid;
                continue;
            };
            const mid_success = result_mid.success;
            result_mid.deinit();
            if (mid_success) {
                hi = mid;
            } else {
                lo = mid;
            }
        }

        const hex = try hexEncodeU64(self.allocator, hi);
        defer self.allocator.free(hex);
        return self.formatResult(id, hex);
    }

    // -----------------------------------------------------------------------
    // Helpers: params extraction
    // -----------------------------------------------------------------------

    /// Return the params array if it has at least `min_len` elements.
    fn expectParamsArray(self: *RpcServer, params: ?std.json.Value, min_len: usize) ?[]const std.json.Value {
        _ = self;
        const p = params orelse return null;
        switch (p) {
            .array => |a| {
                if (a.items.len < min_len) return null;
                return a.items;
            },
            else => return null,
        }
    }

    // -----------------------------------------------------------------------
    // Helpers: JSON-RPC response formatting
    // -----------------------------------------------------------------------

    /// Format a successful JSON-RPC response with a string result.
    fn formatResult(self: *RpcServer, id: ?std.json.Value, result_str: []const u8) ![]u8 {
        var buf = std.ArrayList(u8).init(self.allocator);
        errdefer buf.deinit();
        const w = buf.writer();

        try w.writeAll("{\"jsonrpc\":\"2.0\",\"result\":\"");
        try w.writeAll(result_str);
        try w.writeAll("\",\"id\":");
        try self.writeJsonValue(w, id);
        try w.writeAll("}");

        return buf.toOwnedSlice();
    }

    /// Format an error JSON-RPC response.
    fn formatError(self: *RpcServer, id: ?std.json.Value, code: i64, message: []const u8) ![]u8 {
        var buf = std.ArrayList(u8).init(self.allocator);
        errdefer buf.deinit();
        const w = buf.writer();

        try w.writeAll("{\"jsonrpc\":\"2.0\",\"error\":{\"code\":");
        try std.fmt.formatInt(code, 10, .lower, .{}, w);
        try w.writeAll(",\"message\":\"");
        try w.writeAll(message);
        try w.writeAll("\"},\"id\":");
        try self.writeJsonValue(w, id);
        try w.writeAll("}");

        return buf.toOwnedSlice();
    }

    /// Serialize a std.json.Value as JSON (only handles the types relevant to id).
    fn writeJsonValue(self: *RpcServer, writer: anytype, val: ?std.json.Value) !void {
        _ = self;
        const v = val orelse {
            try writer.writeAll("null");
            return;
        };
        switch (v) {
            .integer => |n| try std.fmt.formatInt(n, 10, .lower, .{}, writer),
            .string => |s| {
                try writer.writeByte('"');
                try writer.writeAll(s);
                try writer.writeByte('"');
            },
            .null => try writer.writeAll("null"),
            else => try writer.writeAll("null"),
        }
    }
};

// ===========================================================================
// Tests
// ===========================================================================

fn makeTestServer() !struct { server: RpcServer, sdb: state.StateDB } {
    const alloc = std.testing.allocator;
    var sdb = state.StateDB.init(alloc);
    return .{
        .server = RpcServer{
            .allocator = alloc,
            .state_db = &sdb,
            .chain_id = 1,
            .block_number = 42,
        },
        .sdb = sdb,
    };
}

// ---------- Hex utility tests ----------

test "hexEncode round-trip" {
    const alloc = std.testing.allocator;
    const input = [_]u8{ 0xde, 0xad, 0xbe, 0xef };
    const hex = try hexEncode(alloc, &input);
    defer alloc.free(hex);
    try std.testing.expectEqualStrings("0xdeadbeef", hex);

    const decoded = try hexDecode(alloc, hex);
    defer alloc.free(decoded);
    try std.testing.expectEqualSlices(u8, &input, decoded);
}

test "hexEncodeU64 minimal" {
    const alloc = std.testing.allocator;
    const z = try hexEncodeU64(alloc, 0);
    defer alloc.free(z);
    try std.testing.expectEqualStrings("0x0", z);

    const x = try hexEncodeU64(alloc, 255);
    defer alloc.free(x);
    try std.testing.expectEqualStrings("0xff", x);
}

test "hexEncodeU256 minimal" {
    const alloc = std.testing.allocator;
    const z = try hexEncodeU256(alloc, U256.zero());
    defer alloc.free(z);
    try std.testing.expectEqualStrings("0x0", z);

    const one = try hexEncodeU256(alloc, U256.fromU64(1));
    defer alloc.free(one);
    try std.testing.expectEqualStrings("0x01", one);
}

test "hexToU256 and hexToAddress" {
    const val = try hexToU256("0xff");
    try std.testing.expect(val.limbs[0] == 255);

    const addr = try hexToAddress("0x0000000000000000000000000000000000000001");
    try std.testing.expect(addr.bytes[19] == 1);
}

// ---------- RPC method tests ----------

test "rpc: eth_chainId returns correct chain ID" {
    const alloc = std.testing.allocator;
    var sdb = state.StateDB.init(alloc);
    defer sdb.deinit();
    var server = RpcServer{
        .allocator = alloc,
        .state_db = &sdb,
        .chain_id = 1,
        .block_number = 42,
    };

    const req =
        \\{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}
    ;
    const resp = try server.handleRequest(req);
    defer alloc.free(resp);

    // Should contain "0x1"
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"0x1\"") != null);
    // Should contain id 1
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"id\":1") != null);
}

test "rpc: eth_blockNumber returns current block" {
    const alloc = std.testing.allocator;
    var sdb = state.StateDB.init(alloc);
    defer sdb.deinit();
    var server = RpcServer{
        .allocator = alloc,
        .state_db = &sdb,
        .chain_id = 1,
        .block_number = 256,
    };

    const req =
        \\{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":2}
    ;
    const resp = try server.handleRequest(req);
    defer alloc.free(resp);

    // 256 = 0x100
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"0x100\"") != null);
}

test "rpc: eth_call with simple contract returning 42" {
    const alloc = std.testing.allocator;
    var sdb = state.StateDB.init(alloc);
    defer sdb.deinit();

    // Deploy bytecode: PUSH1 42, PUSH1 0, MSTORE, PUSH1 32, PUSH1 0, RETURN
    // 60 2a 60 00 52 60 20 60 00 f3
    const contract_addr = try hexToAddress("0x1000000000000000000000000000000000000001");
    const code = [_]u8{ 0x60, 0x2a, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
    try sdb.setCode(contract_addr, &code);

    var server = RpcServer{
        .allocator = alloc,
        .state_db = &sdb,
        .chain_id = 1,
        .block_number = 1,
    };

    const req =
        \\{"jsonrpc":"2.0","method":"eth_call","params":[{"to":"0x1000000000000000000000000000000000000001"},"latest"],"id":3}
    ;
    const resp = try server.handleRequest(req);
    defer alloc.free(resp);

    // Return data should be 32 bytes with 42 (0x2a) at the end
    // 0x000000000000000000000000000000000000000000000000000000000000002a
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"result\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "2a") != null);
}

test "rpc: eth_call with calldata" {
    const alloc = std.testing.allocator;
    var sdb = state.StateDB.init(alloc);
    defer sdb.deinit();

    // Contract: CALLDATALOAD(0), push to return
    // PUSH1 0, CALLDATALOAD, PUSH1 0, MSTORE, PUSH1 32, PUSH1 0, RETURN
    // 60 00 35 60 00 52 60 20 60 00 f3
    const contract_addr = try hexToAddress("0x2000000000000000000000000000000000000002");
    const code = [_]u8{ 0x60, 0x00, 0x35, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
    try sdb.setCode(contract_addr, &code);

    var server = RpcServer{
        .allocator = alloc,
        .state_db = &sdb,
        .chain_id = 1,
        .block_number = 1,
    };

    // Send calldata 0x00...00ff (32 bytes with 0xff at the end)
    const req =
        \\{"jsonrpc":"2.0","method":"eth_call","params":[{"to":"0x2000000000000000000000000000000000000002","data":"0x00000000000000000000000000000000000000000000000000000000000000ff"},"latest"],"id":4}
    ;
    const resp = try server.handleRequest(req);
    defer alloc.free(resp);

    try std.testing.expect(std.mem.indexOf(u8, resp, "\"result\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "ff") != null);
}

test "rpc: eth_estimateGas for simple transfer" {
    const alloc = std.testing.allocator;
    var sdb = state.StateDB.init(alloc);
    defer sdb.deinit();

    const to_addr = try hexToAddress("0x3000000000000000000000000000000000000003");
    // Create the to-account so it exists (no code)
    try sdb.createAccount(to_addr);

    var server = RpcServer{
        .allocator = alloc,
        .state_db = &sdb,
        .chain_id = 1,
        .block_number = 1,
    };

    const req =
        \\{"jsonrpc":"2.0","method":"eth_estimateGas","params":[{"to":"0x3000000000000000000000000000000000000003","value":"0x0"}],"id":5}
    ;
    const resp = try server.handleRequest(req);
    defer alloc.free(resp);

    // Should return exactly 21000 = 0x5208
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"0x5208\"") != null);
}

test "rpc: eth_getBalance of known account" {
    const alloc = std.testing.allocator;
    var sdb = state.StateDB.init(alloc);
    defer sdb.deinit();

    const addr = try hexToAddress("0x4000000000000000000000000000000000000004");
    try sdb.setBalance(addr, U256.fromU64(1_000_000));

    var server = RpcServer{
        .allocator = alloc,
        .state_db = &sdb,
        .chain_id = 1,
        .block_number = 1,
    };

    const req =
        \\{"jsonrpc":"2.0","method":"eth_getBalance","params":["0x4000000000000000000000000000000000000004","latest"],"id":6}
    ;
    const resp = try server.handleRequest(req);
    defer alloc.free(resp);

    // 1_000_000 = 0xf4240
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"result\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "f4240") != null);
}

test "rpc: eth_getCode of known contract" {
    const alloc = std.testing.allocator;
    var sdb = state.StateDB.init(alloc);
    defer sdb.deinit();

    const addr = try hexToAddress("0x5000000000000000000000000000000000000005");
    const code = [_]u8{ 0x60, 0x01, 0x00 }; // PUSH1 1, STOP
    try sdb.setCode(addr, &code);

    var server = RpcServer{
        .allocator = alloc,
        .state_db = &sdb,
        .chain_id = 1,
        .block_number = 1,
    };

    const req =
        \\{"jsonrpc":"2.0","method":"eth_getCode","params":["0x5000000000000000000000000000000000000005","latest"],"id":7}
    ;
    const resp = try server.handleRequest(req);
    defer alloc.free(resp);

    try std.testing.expect(std.mem.indexOf(u8, resp, "\"0x600100\"") != null);
}

test "rpc: eth_getStorageAt of known slot" {
    const alloc = std.testing.allocator;
    var sdb = state.StateDB.init(alloc);
    defer sdb.deinit();

    const addr = try hexToAddress("0x6000000000000000000000000000000000000006");
    try sdb.createAccount(addr);
    try sdb.setStorage(addr, U256.fromU64(0), U256.fromU64(0xbeef));

    var server = RpcServer{
        .allocator = alloc,
        .state_db = &sdb,
        .chain_id = 1,
        .block_number = 1,
    };

    const req =
        \\{"jsonrpc":"2.0","method":"eth_getStorageAt","params":["0x6000000000000000000000000000000000000006","0x0","latest"],"id":8}
    ;
    const resp = try server.handleRequest(req);
    defer alloc.free(resp);

    try std.testing.expect(std.mem.indexOf(u8, resp, "\"result\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "beef") != null);
}

test "rpc: invalid method returns error" {
    const alloc = std.testing.allocator;
    var sdb = state.StateDB.init(alloc);
    defer sdb.deinit();
    var server = RpcServer{
        .allocator = alloc,
        .state_db = &sdb,
        .chain_id = 1,
        .block_number = 1,
    };

    const req =
        \\{"jsonrpc":"2.0","method":"eth_bogus","params":[],"id":9}
    ;
    const resp = try server.handleRequest(req);
    defer alloc.free(resp);

    try std.testing.expect(std.mem.indexOf(u8, resp, "-32601") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "Method not found") != null);
}

test "rpc: malformed JSON returns parse error" {
    const alloc = std.testing.allocator;
    var sdb = state.StateDB.init(alloc);
    defer sdb.deinit();
    var server = RpcServer{
        .allocator = alloc,
        .state_db = &sdb,
        .chain_id = 1,
        .block_number = 1,
    };

    const req = "this is not json";
    const resp = try server.handleRequest(req);
    defer alloc.free(resp);

    try std.testing.expect(std.mem.indexOf(u8, resp, "-32700") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "Parse error") != null);
}

test "rpc: missing method returns invalid request" {
    const alloc = std.testing.allocator;
    var sdb = state.StateDB.init(alloc);
    defer sdb.deinit();
    var server = RpcServer{
        .allocator = alloc,
        .state_db = &sdb,
        .chain_id = 1,
        .block_number = 1,
    };

    const req =
        \\{"jsonrpc":"2.0","id":10}
    ;
    const resp = try server.handleRequest(req);
    defer alloc.free(resp);

    try std.testing.expect(std.mem.indexOf(u8, resp, "-32600") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "Missing method") != null);
}

test "rpc: eth_getBalance with missing params returns error" {
    const alloc = std.testing.allocator;
    var sdb = state.StateDB.init(alloc);
    defer sdb.deinit();
    var server = RpcServer{
        .allocator = alloc,
        .state_db = &sdb,
        .chain_id = 1,
        .block_number = 1,
    };

    const req =
        \\{"jsonrpc":"2.0","method":"eth_getBalance","params":[],"id":11}
    ;
    const resp = try server.handleRequest(req);
    defer alloc.free(resp);

    try std.testing.expect(std.mem.indexOf(u8, resp, "-32602") != null);
}
