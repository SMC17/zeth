# Initial GitHub Issues to Create

After pushing, create these issues to kickstart development:

## Critical Path Issues

### Issue #1: Implement proper Keccak-256 hashing
**Labels**: `critical`, `cryptography`, `good first issue`
**Priority**: P0

We're currently using SHA3-256 as a placeholder, but Ethereum uses Keccak-256 (pre-NIST SHA3). This is blocking real transaction validation.

**Tasks**:
- [ ] Research Keccak-256 vs SHA3-256 differences
- [ ] Implement or integrate proper Keccak-256
- [ ] Add comprehensive tests
- [ ] Benchmark performance

**Resources**:
- https://ethereum.org/en/developers/docs/data-structures-and-encoding/rlp/
- https://github.com/ethereum/go-ethereum/tree/master/crypto

---

### Issue #2: Complete secp256k1 implementation
**Labels**: `critical`, `cryptography`
**Priority**: P0

Need full secp256k1 support for signature operations.

**Tasks**:
- [ ] Implement/integrate secp256k1 signing
- [ ] Implement signature verification
- [ ] Implement public key recovery
- [ ] Add test vectors from Ethereum tests

---

### Issue #3: Expand EVM opcode coverage
**Labels**: `evm`, `help wanted`
**Priority**: P0

Currently have ~15 opcodes. Need 150+.

**Tasks**:
- [ ] Audit current opcodes
- [ ] Prioritize opcodes by usage frequency
- [ ] Implement arithmetic opcodes (remaining)
- [ ] Implement comparison & bitwise opcodes
- [ ] Implement SHA3 opcode
- [ ] Implement environmental opcodes
- [ ] Implement block information opcodes

**Good sub-issues to create for each opcode family**

---

### Issue #4: Implement Ethereum test vector integration
**Labels**: `testing`, `good first issue`
**Priority**: P1

Integrate official Ethereum test vectors to validate our implementation.

**Tasks**:
- [ ] Download Ethereum tests repository
- [ ] Parse test JSON format
- [ ] Run RLP tests
- [ ] Run state tests
- [ ] Run VM tests
- [ ] Set up CI to run tests

**Resources**:
- https://github.com/ethereum/tests

---

### Issue #5: Add comprehensive RLP edge case tests
**Labels**: `testing`, `good first issue`
**Priority**: P1

Expand RLP test coverage beyond happy path.

**Tasks**:
- [ ] Test malformed RLP
- [ ] Test maximum sizes
- [ ] Test nested structures
- [ ] Property-based testing with fuzzing

---

## Foundation Issues

### Issue #6: Set up continuous integration
**Labels**: `infrastructure`, `good first issue`
**Priority**: P1

**Tasks**:
- [ ] GitHub Actions for build
- [ ] Run tests on PR
- [ ] Multi-platform testing (Linux, macOS, Windows)
- [ ] Code coverage reporting

---

### Issue #7: Add benchmarking infrastructure
**Labels**: `performance`, `testing`
**Priority**: P2

**Tasks**:
- [ ] Create benchmark framework
- [ ] Benchmark cryptographic operations
- [ ] Benchmark RLP encoding/decoding
- [ ] Benchmark EVM execution
- [ ] Track performance over time

---

### Issue #8: Implement precompiled contracts
**Labels**: `evm`, `cryptography`
**Priority**: P1

**Tasks**:
- [ ] ecrecover (address recovery)
- [ ] SHA2-256
- [ ] RIPEMD-160
- [ ] Identity
- [ ] ModExp
- [ ] BN256Add, BN256Mul, BN256Pairing
- [ ] Blake2F

---

### Issue #9: DevP2P protocol implementation
**Labels**: `networking`, `help wanted`
**Priority**: P0

**Tasks**:
- [ ] RLPx transport layer
- [ ] Encryption/authentication
- [ ] Protocol handshake
- [ ] Ping/pong keepalive
- [ ] Peer discovery
- [ ] DHT implementation

---

### Issue #10: Implement database persistence layer
**Labels**: `storage`, `help wanted`
**Priority**: P1

**Tasks**:
- [ ] Evaluate LevelDB vs RocksDB
- [ ] Create database abstraction layer
- [ ] Implement state trie persistence
- [ ] Implement block storage
- [ ] Implement transaction indexing
- [ ] Add database tests

---

## Documentation Issues

### Issue #11: Create developer onboarding guide
**Labels**: `documentation`, `good first issue`
**Priority**: P2

**Tasks**:
- [ ] Environment setup guide
- [ ] Code walkthrough
- [ ] Architecture explanation
- [ ] How to add a new opcode
- [ ] Testing guide

---

### Issue #12: Document Ethereum concepts for Zig developers
**Labels**: `documentation`
**Priority**: P2

Help Zig developers understand Ethereum.

**Tasks**:
- [ ] Explain transactions, blocks, state
- [ ] Explain gas and fees
- [ ] Explain the EVM
- [ ] Explain consensus
- [ ] Glossary of terms

---

### Issue #13: Create example programs
**Labels**: `documentation`, `examples`
**Priority**: P2

**Tasks**:
- [ ] Create transaction example
- [ ] Create smart contract execution example
- [ ] Create state query example
- [ ] Create block parsing example

---

## Enhancement Issues

### Issue #14: Add fuzzing for RLP parser
**Labels**: `testing`, `security`
**Priority**: P1

Use fuzzing to find edge cases and potential crashes.

---

### Issue #15: Optimize U256 arithmetic
**Labels**: `performance`, `optimization`
**Priority**: P2

Current U256 implementation is basic. Optimize for performance.

**Tasks**:
- [ ] Profile current performance
- [ ] Implement optimized multiplication
- [ ] Implement optimized division
- [ ] Use Zig's @Vector for SIMD where possible
- [ ] Benchmark improvements

---

### Issue #16: Implement transaction pool (mempool)
**Labels**: `feature`, `help wanted`
**Priority**: P1

**Tasks**:
- [ ] Design mempool data structure
- [ ] Implement transaction validation
- [ ] Implement gas price sorting
- [ ] Implement transaction replacement
- [ ] Implement eviction policies

---

### Issue #17: JSON-RPC server implementation
**Labels**: `api`, `help wanted`
**Priority**: P1

**Tasks**:
- [ ] HTTP server setup
- [ ] WebSocket support
- [ ] Implement eth_* methods
- [ ] Implement web3_* methods
- [ ] Add request batching
- [ ] Add authentication (optional)

---

## Community Issues

### Issue #18: Set up Discord server
**Labels**: `community`
**Priority**: P2

Create Discord for real-time communication.

---

### Issue #19: Create Twitter account and posting schedule
**Labels**: `community`, `marketing`
**Priority**: P2

Build social media presence.

---

### Issue #20: Write blog post: "Why Zeth?"
**Labels**: `documentation`, `community`
**Priority**: P2

Explain the motivation and vision for Zeth.

---

## Instructions

After pushing to GitHub:
1. Go to https://github.com/SMC17/eth-zig/issues
2. Click "New Issue"
3. Copy each issue above
4. Add appropriate labels
5. Set milestone if applicable
6. Engage with the community!

