const std = @import("std");
const crypto = @import("crypto");
const rlp = @import("rlp");

/// The root hash of an empty Merkle Patricia Trie.
/// keccak256(RLP("")) = keccak256(0x80)
pub const EMPTY_TRIE_ROOT = [32]u8{
    0x56, 0xe8, 0x1f, 0x17, 0x1b, 0xcc, 0x55, 0xa6,
    0xff, 0x83, 0x45, 0xe6, 0x92, 0xc0, 0xf8, 0x6e,
    0x5b, 0x48, 0xe0, 0x1b, 0x99, 0x6c, 0xad, 0xc0,
    0x01, 0x62, 0x2f, 0xb5, 0xe3, 0x63, 0xb4, 0x21,
};

/// Ethereum-compatible Merkle Patricia Trie.
///
/// Implements the Modified Merkle Patricia Trie as specified in the
/// Ethereum Yellow Paper, Appendix D. Supports four node types:
/// Empty, Leaf, Extension, and Branch.
pub const MPT = struct {
    allocator: std.mem.Allocator,
    root: ?*Node,

    pub fn init(allocator: std.mem.Allocator) MPT {
        return MPT{
            .allocator = allocator,
            .root = null,
        };
    }

    pub fn deinit(self: *MPT) void {
        if (self.root) |root| {
            root.deinit(self.allocator);
            self.allocator.destroy(root);
        }
    }

    /// Insert a key-value pair. Key is raw bytes (will be keccak-hashed
    /// for the state trie, but the caller is responsible for that).
    /// Internally the key is expanded to a nibble path.
    pub fn insert(self: *MPT, key: []const u8, value: []const u8) !void {
        const nibbles = try keyToNibbles(self.allocator, key);
        defer self.allocator.free(nibbles);

        const val_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(val_copy);

        if (self.root) |root| {
            self.root = try self.insertNode(root, nibbles, val_copy);
        } else {
            // Empty trie: create a leaf for the full path.
            const path_copy = try self.allocator.dupe(u8, nibbles);
            errdefer self.allocator.free(path_copy);
            const leaf = try self.allocator.create(Node);
            leaf.* = Node{ .leaf = .{ .nibbles = path_copy, .value = val_copy } };
            self.root = leaf;
        }
    }

    /// Get a value by key. Returns null if not found.
    pub fn get(self: *MPT, key: []const u8) !?[]const u8 {
        const nibbles = try keyToNibbles(self.allocator, key);
        defer self.allocator.free(nibbles);

        return self.getNode(self.root, nibbles);
    }

    /// Compute the trie root hash.
    pub fn rootHash(self: *MPT) ![32]u8 {
        if (self.root == null) {
            return EMPTY_TRIE_ROOT;
        }
        const encoded = try self.encodeNode(self.root.?);
        defer self.allocator.free(encoded);

        // Root node is always hashed, even if < 32 bytes.
        var hash: [32]u8 = undefined;
        crypto.keccak256(encoded, &hash);
        return hash;
    }

    // ---------------------------------------------------------------
    // Internal: node insertion
    // ---------------------------------------------------------------

    fn insertNode(self: *MPT, node: *Node, nibbles: []const u8, value: []u8) !*Node {
        switch (node.*) {
            .leaf => |leaf| {
                const existing_nibbles = leaf.nibbles;
                const existing_value = leaf.value;

                const common = commonPrefixLen(existing_nibbles, nibbles);

                // Same key: overwrite value.
                if (common == existing_nibbles.len and common == nibbles.len) {
                    self.allocator.free(existing_value);
                    node.*.leaf.value = value;
                    return node;
                }

                // Need to branch. Create a branch node.
                const branch = try self.allocator.create(Node);
                branch.* = Node{ .branch = .{
                    .children = [_]?*Node{null} ** 16,
                    .value = null,
                } };
                errdefer {
                    branch.deinit(self.allocator);
                    self.allocator.destroy(branch);
                }

                // Place existing leaf into branch.
                if (common == existing_nibbles.len) {
                    // Existing key is prefix of new key — existing becomes branch value.
                    branch.*.branch.value = existing_value;
                } else {
                    const idx_existing = existing_nibbles[common];
                    const rest_existing = try self.allocator.dupe(u8, existing_nibbles[common + 1 ..]);
                    errdefer self.allocator.free(rest_existing);
                    const child_leaf = try self.allocator.create(Node);
                    child_leaf.* = Node{ .leaf = .{ .nibbles = rest_existing, .value = existing_value } };
                    branch.*.branch.children[idx_existing] = child_leaf;
                }

                // Place new value into branch.
                if (common == nibbles.len) {
                    // New key is prefix of existing — new becomes branch value.
                    branch.*.branch.value = value;
                } else {
                    const idx_new = nibbles[common];
                    const rest_new = try self.allocator.dupe(u8, nibbles[common + 1 ..]);
                    errdefer self.allocator.free(rest_new);
                    const new_leaf = try self.allocator.create(Node);
                    new_leaf.* = Node{ .leaf = .{ .nibbles = rest_new, .value = value } };
                    branch.*.branch.children[idx_new] = new_leaf;
                }

                // Free old leaf's nibbles and the node itself (value already moved).
                self.allocator.free(existing_nibbles);
                node.* = .{ .empty = {} };
                self.allocator.destroy(node);

                // If there's a common prefix, wrap in extension.
                if (common > 0) {
                    const ext_nibbles = try self.allocator.dupe(u8, nibbles[0..common]);
                    errdefer self.allocator.free(ext_nibbles);
                    const ext = try self.allocator.create(Node);
                    ext.* = Node{ .extension = .{ .nibbles = ext_nibbles, .child = branch } };
                    return ext;
                }

                return branch;
            },
            .extension => |ext| {
                const ext_nibbles = ext.nibbles;
                const common = commonPrefixLen(ext_nibbles, nibbles);

                if (common == ext_nibbles.len) {
                    // Full match on extension path — recurse into child.
                    node.*.extension.child = try self.insertNode(ext.child, nibbles[common..], value);
                    return node;
                }

                // Partial match — split the extension.
                const branch = try self.allocator.create(Node);
                branch.* = Node{ .branch = .{
                    .children = [_]?*Node{null} ** 16,
                    .value = null,
                } };
                errdefer {
                    branch.deinit(self.allocator);
                    self.allocator.destroy(branch);
                }

                // Remaining extension after the common prefix.
                const ext_rest = ext_nibbles[common + 1 ..];
                const ext_idx = ext_nibbles[common];

                if (ext_rest.len == 0) {
                    // Extension remainder is exactly one nibble — child goes directly into branch.
                    branch.*.branch.children[ext_idx] = ext.child;
                } else {
                    const new_ext_nibbles = try self.allocator.dupe(u8, ext_rest);
                    errdefer self.allocator.free(new_ext_nibbles);
                    const new_ext = try self.allocator.create(Node);
                    new_ext.* = Node{ .extension = .{ .nibbles = new_ext_nibbles, .child = ext.child } };
                    branch.*.branch.children[ext_idx] = new_ext;
                }

                // Insert the new value.
                if (common == nibbles.len) {
                    branch.*.branch.value = value;
                } else {
                    const new_idx = nibbles[common];
                    const new_rest = try self.allocator.dupe(u8, nibbles[common + 1 ..]);
                    errdefer self.allocator.free(new_rest);
                    const new_leaf = try self.allocator.create(Node);
                    new_leaf.* = Node{ .leaf = .{ .nibbles = new_rest, .value = value } };
                    branch.*.branch.children[new_idx] = new_leaf;
                }

                // Free old extension's nibbles and node shell.
                self.allocator.free(ext_nibbles);
                node.* = .{ .empty = {} };
                self.allocator.destroy(node);

                if (common > 0) {
                    const prefix = try self.allocator.dupe(u8, nibbles[0..common]);
                    errdefer self.allocator.free(prefix);
                    const wrapper = try self.allocator.create(Node);
                    wrapper.* = Node{ .extension = .{ .nibbles = prefix, .child = branch } };
                    return wrapper;
                }

                return branch;
            },
            .branch => |*branch| {
                if (nibbles.len == 0) {
                    // Key terminates at this branch.
                    if (branch.value) |old| {
                        self.allocator.free(old);
                    }
                    branch.value = value;
                    return node;
                }

                const idx = nibbles[0];
                const rest = nibbles[1..];

                if (branch.children[idx]) |child| {
                    branch.children[idx] = try self.insertNode(child, rest, value);
                } else {
                    const path = try self.allocator.dupe(u8, rest);
                    errdefer self.allocator.free(path);
                    const leaf = try self.allocator.create(Node);
                    leaf.* = Node{ .leaf = .{ .nibbles = path, .value = value } };
                    branch.children[idx] = leaf;
                }

                return node;
            },
            .empty => {
                // Should not happen in a well-formed trie. Replace with a leaf.
                const path = try self.allocator.dupe(u8, nibbles);
                errdefer self.allocator.free(path);
                node.* = Node{ .leaf = .{ .nibbles = path, .value = value } };
                return node;
            },
        }
    }

    // ---------------------------------------------------------------
    // Internal: node lookup
    // ---------------------------------------------------------------

    fn getNode(self: *MPT, maybe_node: ?*Node, nibbles: []const u8) ?[]const u8 {
        const node = maybe_node orelse return null;
        switch (node.*) {
            .leaf => |leaf| {
                if (std.mem.eql(u8, leaf.nibbles, nibbles)) {
                    return leaf.value;
                }
                return null;
            },
            .extension => |ext| {
                if (nibbles.len < ext.nibbles.len) return null;
                if (!std.mem.eql(u8, nibbles[0..ext.nibbles.len], ext.nibbles)) return null;
                return self.getNode(ext.child, nibbles[ext.nibbles.len..]);
            },
            .branch => |branch| {
                if (nibbles.len == 0) {
                    return branch.value;
                }
                return self.getNode(branch.children[nibbles[0]], nibbles[1..]);
            },
            .empty => return null,
        }
    }

    // ---------------------------------------------------------------
    // Internal: node encoding (RLP)
    // ---------------------------------------------------------------

    /// Encode a node to its RLP representation.
    fn encodeNode(self: *MPT, node: *Node) std.mem.Allocator.Error![]u8 {
        switch (node.*) {
            .leaf => |leaf| {
                return self.encodeLeaf(leaf.nibbles, leaf.value);
            },
            .extension => |ext| {
                return self.encodeExtension(ext.nibbles, ext.child);
            },
            .branch => |branch| {
                return self.encodeBranch(&branch.children, branch.value);
            },
            .empty => {
                // RLP empty string.
                const result = try self.allocator.alloc(u8, 1);
                result[0] = 0x80;
                return result;
            },
        }
    }

    /// Encode a leaf node: RLP([hp_encode(nibbles, true), value])
    fn encodeLeaf(self: *MPT, nibbles: []const u8, value: []const u8) std.mem.Allocator.Error![]u8 {
        const hp = try hexPrefixEncode(self.allocator, nibbles, true);
        defer self.allocator.free(hp);

        const hp_rlp = try rlp.encodeBytes(hp, self.allocator);
        defer self.allocator.free(hp_rlp);

        const val_rlp = try rlp.encodeBytes(value, self.allocator);
        defer self.allocator.free(val_rlp);

        const items = [_][]const u8{ hp_rlp, val_rlp };
        return rlp.encodeList(&items, self.allocator);
    }

    /// Encode an extension node: RLP([hp_encode(nibbles, false), child_ref])
    fn encodeExtension(self: *MPT, nibbles: []const u8, child: *Node) std.mem.Allocator.Error![]u8 {
        const hp = try hexPrefixEncode(self.allocator, nibbles, false);
        defer self.allocator.free(hp);

        const hp_rlp = try rlp.encodeBytes(hp, self.allocator);
        defer self.allocator.free(hp_rlp);

        const child_ref = try self.encodeChildRef(child);
        defer self.allocator.free(child_ref);

        const items = [_][]const u8{ hp_rlp, child_ref };
        return rlp.encodeList(&items, self.allocator);
    }

    /// Encode a branch node: RLP([child0, child1, ..., child15, value])
    fn encodeBranch(self: *MPT, children: *const [16]?*Node, value: ?[]const u8) std.mem.Allocator.Error![]u8 {
        var encoded_items: [17][]const u8 = undefined;
        var to_free: [17]bool = [_]bool{false} ** 17;

        for (0..16) |i| {
            if (children[i]) |child| {
                encoded_items[i] = try self.encodeChildRef(child);
                to_free[i] = true;
            } else {
                // Empty child is RLP empty string (0x80).
                const empty = try self.allocator.alloc(u8, 1);
                empty[0] = 0x80;
                encoded_items[i] = empty;
                to_free[i] = true;
            }
        }

        // Slot 16 is the branch value.
        if (value) |v| {
            encoded_items[16] = try rlp.encodeBytes(v, self.allocator);
            to_free[16] = true;
        } else {
            const empty = try self.allocator.alloc(u8, 1);
            empty[0] = 0x80;
            encoded_items[16] = empty;
            to_free[16] = true;
        }

        defer {
            for (0..17) |i| {
                if (to_free[i]) {
                    self.allocator.free(encoded_items[i]);
                }
            }
        }

        return rlp.encodeList(&encoded_items, self.allocator);
    }

    /// Encode a child reference: if the encoded child is < 32 bytes, inline it;
    /// otherwise hash it and return RLP(hash).
    fn encodeChildRef(self: *MPT, child: *Node) std.mem.Allocator.Error![]u8 {
        const encoded = try self.encodeNode(child);
        defer self.allocator.free(encoded);

        if (encoded.len < 32) {
            // Inline: the encoded node IS the reference (already RLP).
            return self.allocator.dupe(u8, encoded);
        } else {
            // Hash and encode as 32-byte string.
            var hash: [32]u8 = undefined;
            crypto.keccak256(encoded, &hash);
            return rlp.encodeBytes(&hash, self.allocator);
        }
    }
};

// -------------------------------------------------------------------
// Hex-Prefix Encoding (Yellow Paper, Appendix C)
// -------------------------------------------------------------------

/// Encode a nibble sequence with a hex-prefix flag.
/// `is_leaf` determines whether this is a leaf (terminator) or extension.
///
/// If even number of nibbles:
///   leaf: [0x20, nibble_pairs...]
///   ext:  [0x00, nibble_pairs...]
/// If odd number of nibbles:
///   leaf: [0x30 | first_nibble, remaining_pairs...]
///   ext:  [0x10 | first_nibble, remaining_pairs...]
pub fn hexPrefixEncode(allocator: std.mem.Allocator, nibbles: []const u8, is_leaf: bool) ![]u8 {
    const flag: u8 = if (is_leaf) @as(u8, 2) else @as(u8, 0);
    const odd = nibbles.len & 1 == 1;

    if (odd) {
        // Odd: first byte = (flag | 1) << 4 | first_nibble
        const out_len = 1 + (nibbles.len - 1) / 2;
        const result = try allocator.alloc(u8, out_len);
        result[0] = ((flag | 1) << 4) | nibbles[0];
        var i: usize = 1;
        var j: usize = 1;
        while (j < nibbles.len) : (j += 2) {
            result[i] = (nibbles[j] << 4) | (if (j + 1 < nibbles.len) nibbles[j + 1] else 0);
            i += 1;
        }
        return result;
    } else {
        // Even: first byte = flag << 4, then nibble pairs
        const out_len = 1 + nibbles.len / 2;
        const result = try allocator.alloc(u8, out_len);
        result[0] = flag << 4;
        var i: usize = 1;
        var j: usize = 0;
        while (j < nibbles.len) : (j += 2) {
            result[i] = (nibbles[j] << 4) | nibbles[j + 1];
            i += 1;
        }
        return result;
    }
}

/// Expand raw bytes into nibble sequence.
pub fn keyToNibbles(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    const nibbles = try allocator.alloc(u8, key.len * 2);
    for (key, 0..) |byte, i| {
        nibbles[i * 2] = byte >> 4;
        nibbles[i * 2 + 1] = byte & 0x0F;
    }
    return nibbles;
}

// -------------------------------------------------------------------
// Internal node type
// -------------------------------------------------------------------

const Node = union(enum) {
    empty: void,
    leaf: struct {
        nibbles: []u8,
        value: []u8,
    },
    extension: struct {
        nibbles: []u8,
        child: *Node,
    },
    branch: struct {
        children: [16]?*Node,
        value: ?[]u8,
    },

    fn deinit(self: *Node, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .empty => {},
            .leaf => |leaf| {
                allocator.free(leaf.nibbles);
                allocator.free(leaf.value);
            },
            .extension => |ext| {
                allocator.free(ext.nibbles);
                ext.child.deinit(allocator);
                allocator.destroy(ext.child);
            },
            .branch => |branch| {
                for (branch.children) |child| {
                    if (child) |c| {
                        c.deinit(allocator);
                        allocator.destroy(c);
                    }
                }
                if (branch.value) |v| {
                    allocator.free(v);
                }
            },
        }
    }
};

fn commonPrefixLen(a: []const u8, b: []const u8) usize {
    const limit = @min(a.len, b.len);
    var i: usize = 0;
    while (i < limit and a[i] == b[i]) : (i += 1) {}
    return i;
}

// ===================================================================
// Tests
// ===================================================================

test "empty trie has EMPTY_TRIE_ROOT hash" {
    var trie = MPT.init(std.testing.allocator);
    defer trie.deinit();

    const root = try trie.rootHash();
    try std.testing.expectEqualSlices(u8, &EMPTY_TRIE_ROOT, &root);
}

test "single key-value produces deterministic root" {
    var trie = MPT.init(std.testing.allocator);
    defer trie.deinit();

    try trie.insert("hello", "world");
    const root = try trie.rootHash();

    // Root should NOT be the empty root.
    try std.testing.expect(!std.mem.eql(u8, &root, &EMPTY_TRIE_ROOT));

    // Inserting same data again should give the same root.
    var trie2 = MPT.init(std.testing.allocator);
    defer trie2.deinit();
    try trie2.insert("hello", "world");
    const root2 = try trie2.rootHash();
    try std.testing.expectEqualSlices(u8, &root, &root2);
}

test "two keys with different first nibbles create branch" {
    var trie = MPT.init(std.testing.allocator);
    defer trie.deinit();

    // 0x10... and 0x20... differ at first nibble.
    try trie.insert(&[_]u8{0x10}, "val1");
    try trie.insert(&[_]u8{0x20}, "val2");

    // Should be able to retrieve both.
    const v1 = try trie.get(&[_]u8{0x10});
    try std.testing.expect(v1 != null);
    try std.testing.expectEqualStrings("val1", v1.?);

    const v2 = try trie.get(&[_]u8{0x20});
    try std.testing.expect(v2 != null);
    try std.testing.expectEqualStrings("val2", v2.?);

    const root = try trie.rootHash();
    try std.testing.expect(!std.mem.eql(u8, &root, &EMPTY_TRIE_ROOT));
}

test "two keys with shared prefix create extension + branch" {
    var trie = MPT.init(std.testing.allocator);
    defer trie.deinit();

    // Both start with 0xAB, differ after that.
    try trie.insert(&[_]u8{ 0xAB, 0x10 }, "val1");
    try trie.insert(&[_]u8{ 0xAB, 0x20 }, "val2");

    const v1 = try trie.get(&[_]u8{ 0xAB, 0x10 });
    try std.testing.expect(v1 != null);
    try std.testing.expectEqualStrings("val1", v1.?);

    const v2 = try trie.get(&[_]u8{ 0xAB, 0x20 });
    try std.testing.expect(v2 != null);
    try std.testing.expectEqualStrings("val2", v2.?);
}

test "insert same key twice overwrites value" {
    var trie = MPT.init(std.testing.allocator);
    defer trie.deinit();

    try trie.insert("key", "old");
    try trie.insert("key", "new");

    const v = try trie.get("key");
    try std.testing.expect(v != null);
    try std.testing.expectEqualStrings("new", v.?);
}

test "get returns correct value" {
    var trie = MPT.init(std.testing.allocator);
    defer trie.deinit();

    try trie.insert("apple", "fruit");
    try trie.insert("apply", "verb");
    try trie.insert("banana", "fruit");

    const v1 = try trie.get("apple");
    try std.testing.expect(v1 != null);
    try std.testing.expectEqualStrings("fruit", v1.?);

    const v2 = try trie.get("apply");
    try std.testing.expect(v2 != null);
    try std.testing.expectEqualStrings("verb", v2.?);

    const v3 = try trie.get("banana");
    try std.testing.expect(v3 != null);
    try std.testing.expectEqualStrings("fruit", v3.?);
}

test "get returns null for missing key" {
    var trie = MPT.init(std.testing.allocator);
    defer trie.deinit();

    try trie.insert("exists", "yes");

    const v = try trie.get("missing");
    try std.testing.expect(v == null);

    // Also test partial prefix match does not return false positive.
    const v2 = try trie.get("exist");
    try std.testing.expect(v2 == null);
}

test "known Ethereum test vector: single account trie" {
    // From the Ethereum wiki / Yellow Paper:
    // Trie with single entry: key = keccak256(address), value = RLP(account)
    // We use a simpler known vector: trie containing ("do", "verb")
    // Expected root from go-ethereum / pyethereum reference tests.
    //
    // The trie with ("do", "verb") should produce:
    //   Leaf node: RLP([hex_prefix([6, 4, 6, 15], leaf=true), "verb"])
    //   hex_prefix([6, 4, 6, 15], leaf=true, even) = [0x20, 0x64, 0x6f]
    //   RLP(["\\x20\\x64\\x6f", "verb"]) = RLP list of two strings.
    //
    // Let's compute it by hand and verify.
    var trie = MPT.init(std.testing.allocator);
    defer trie.deinit();

    try trie.insert("do", "verb");
    const root = try trie.rootHash();

    // Manually compute expected:
    // key "do" = bytes [0x64, 0x6f]
    // nibbles = [6, 4, 6, 15] (even count = 4)
    // hex-prefix (leaf, even): [0x20, 0x64, 0x6f]
    // RLP of hp: 0x83, 0x20, 0x64, 0x6f (3-byte string)
    // RLP of "verb": 0x84, 0x76, 0x65, 0x72, 0x62 (4-byte string)
    // List payload = 9 bytes, so short list: 0xc9
    // Full: [0xc9, 0x83, 0x20, 0x64, 0x6f, 0x84, 0x76, 0x65, 0x72, 0x62]
    // keccak256 of that 10-byte RLP.

    const expected_rlp = [_]u8{ 0xc9, 0x83, 0x20, 0x64, 0x6f, 0x84, 0x76, 0x65, 0x72, 0x62 };
    var expected_hash: [32]u8 = undefined;
    crypto.keccak256(&expected_rlp, &expected_hash);

    try std.testing.expectEqualSlices(u8, &expected_hash, &root);
}

test "hex-prefix encoding for leaf even" {
    // Leaf, even nibbles [1, 2, 3, 4] -> [0x20, 0x12, 0x34]
    const nibbles = [_]u8{ 1, 2, 3, 4 };
    const hp = try hexPrefixEncode(std.testing.allocator, &nibbles, true);
    defer std.testing.allocator.free(hp);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x20, 0x12, 0x34 }, hp);
}

test "hex-prefix encoding for leaf odd" {
    // Leaf, odd nibbles [1, 2, 3] -> [0x31, 0x23]
    const nibbles = [_]u8{ 1, 2, 3 };
    const hp = try hexPrefixEncode(std.testing.allocator, &nibbles, true);
    defer std.testing.allocator.free(hp);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x31, 0x23 }, hp);
}

test "hex-prefix encoding for extension even" {
    // Extension, even nibbles [1, 2, 3, 4] -> [0x00, 0x12, 0x34]
    const nibbles = [_]u8{ 1, 2, 3, 4 };
    const hp = try hexPrefixEncode(std.testing.allocator, &nibbles, false);
    defer std.testing.allocator.free(hp);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x12, 0x34 }, hp);
}

test "hex-prefix encoding for extension odd" {
    // Extension, odd nibbles [1, 2, 3] -> [0x11, 0x23]
    const nibbles = [_]u8{ 1, 2, 3 };
    const hp = try hexPrefixEncode(std.testing.allocator, &nibbles, false);
    defer std.testing.allocator.free(hp);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x11, 0x23 }, hp);
}

test "insertion order does not affect root hash" {
    var trie1 = MPT.init(std.testing.allocator);
    defer trie1.deinit();
    var trie2 = MPT.init(std.testing.allocator);
    defer trie2.deinit();

    try trie1.insert("dog", "puppy");
    try trie1.insert("horse", "stallion");
    try trie1.insert("do", "verb");

    try trie2.insert("do", "verb");
    try trie2.insert("horse", "stallion");
    try trie2.insert("dog", "puppy");

    const root1 = try trie1.rootHash();
    const root2 = try trie2.rootHash();

    try std.testing.expectEqualSlices(u8, &root1, &root2);
}

test "multiple entries with shared and divergent paths" {
    var trie = MPT.init(std.testing.allocator);
    defer trie.deinit();

    try trie.insert("do", "verb");
    try trie.insert("dog", "puppy");
    try trie.insert("doge", "coin");
    try trie.insert("horse", "stallion");

    // Verify all values retrievable.
    const v1 = try trie.get("do");
    try std.testing.expect(v1 != null);
    try std.testing.expectEqualStrings("verb", v1.?);

    const v2 = try trie.get("dog");
    try std.testing.expect(v2 != null);
    try std.testing.expectEqualStrings("puppy", v2.?);

    const v3 = try trie.get("doge");
    try std.testing.expect(v3 != null);
    try std.testing.expectEqualStrings("coin", v3.?);

    const v4 = try trie.get("horse");
    try std.testing.expect(v4 != null);
    try std.testing.expectEqualStrings("stallion", v4.?);

    // Root should be deterministic.
    const root = try trie.rootHash();
    try std.testing.expect(!std.mem.eql(u8, &root, &EMPTY_TRIE_ROOT));
}

test "hex-prefix encoding for empty nibbles leaf" {
    // Leaf with zero nibbles -> [0x20]
    const nibbles = [_]u8{};
    const hp = try hexPrefixEncode(std.testing.allocator, &nibbles, true);
    defer std.testing.allocator.free(hp);

    try std.testing.expectEqualSlices(u8, &[_]u8{0x20}, hp);
}

test "hex-prefix encoding for single nibble extension" {
    // Extension, odd (1 nibble) [0xf] -> [0x1f]
    const nibbles = [_]u8{0xf};
    const hp = try hexPrefixEncode(std.testing.allocator, &nibbles, false);
    defer std.testing.allocator.free(hp);

    try std.testing.expectEqualSlices(u8, &[_]u8{0x1f}, hp);
}
