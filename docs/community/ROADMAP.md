# Zeth Roadmap

**Vision**: Build the most advanced, optimized, performant, and secure Ethereum implementation in Zig.

**Mission**: Create a production-ready Ethereum client that serves as the go-to integration layer for the Ethereum ecosystem, leveraging Zig's safety, performance, and simplicity.

---

## Current Status (v0.1.0-alpha)

**Lines of Code**: 1,351
**Tests**: 14 passing
**Zig Version**: 0.15.1

### What Works Today ✅
- Core types (Address, Hash, U256, Transaction, Block)
- RLP encoding/decoding
- Basic EVM (~15 opcodes)
- State management
- Merkle Patricia Trie (basic)
- Comprehensive test suite

### What's Missing ⚠️
- Full cryptography (proper Keccak-256, secp256k1)
- Complete EVM (135+ more opcodes)
- Networking layer
- Consensus mechanisms
- JSON-RPC API
- Database persistence
- Real-world testing

---

## Phase 1: Foundation (Q1 2025) - **IN PROGRESS**

**Goal**: Solid cryptographic and EVM foundation

### Milestones

#### 1.1 Complete Cryptography
- [ ] Proper Keccak-256 implementation (not SHA3)
- [ ] Full secp256k1 (sign, verify, recover)
- [ ] BLS signatures (for consensus)
- [ ] Integration with existing crypto libraries
- **Why**: Foundation for all Ethereum operations
- **Issues**: #1, #2, #3

#### 1.2 Expand EVM
- [ ] Complete all 150+ opcodes
- [ ] Precompiled contracts (ecrecover, sha256, ripemd160, etc.)
- [ ] Gas cost calculations (Berlin/London/Shanghai rules)
- [ ] Transaction execution context
- [ ] Event log generation
- **Why**: Core functionality for smart contract execution
- **Issues**: #4, #5, #6, #7

#### 1.3 Testing Infrastructure
- [ ] Ethereum test vector integration
- [ ] Fuzzing infrastructure
- [ ] Performance benchmarks
- [ ] CI/CD pipeline
- **Why**: Ensure correctness and prevent regressions
- **Issues**: #8, #9

**Deliverable**: A working EVM that can execute real smart contracts

---

## Phase 2: Networking (Q2 2025)

**Goal**: Connect to the Ethereum network

### Milestones

#### 2.1 DevP2P Protocol
- [ ] RLPx transport layer
- [ ] Node discovery (Kademlia DHT)
- [ ] Peer management
- [ ] Protocol handshaking
- **Issues**: #10, #11, #12

#### 2.2 ETH Wire Protocol
- [ ] Block propagation
- [ ] Transaction gossip
- [ ] State synchronization
- [ ] Snap sync protocol
- **Issues**: #13, #14, #15

#### 2.3 Network Testing
- [ ] Testnet connectivity (Sepolia, Holesky)
- [ ] Peer discovery verification
- [ ] Mainnet monitoring (read-only)
- **Issues**: #16, #17

**Deliverable**: A node that can sync and participate in the Ethereum network

---

## Phase 3: Consensus & Storage (Q3 2025)

**Goal**: Full node capabilities with persistence

### Milestones

#### 3.1 Database Layer
- [ ] LevelDB/RocksDB integration
- [ ] State trie persistence
- [ ] Block storage
- [ ] Transaction indexing
- [ ] Pruning strategies
- **Issues**: #18, #19, #20

#### 3.2 Consensus Implementation
- [ ] Proof of Stake (Casper FFG)
- [ ] Beacon chain integration
- [ ] Fork choice rule
- [ ] Validator duties
- [ ] Attestation aggregation
- **Issues**: #21, #22, #23

#### 3.3 Transaction Pool
- [ ] Mempool management
- [ ] Transaction validation
- [ ] Gas price sorting
- [ ] Replacement logic
- **Issues**: #24, #25

**Deliverable**: A full node that can validate and store the blockchain

---

## Phase 4: JSON-RPC & Tooling (Q4 2025)

**Goal**: Production-ready with full API support

### Milestones

#### 4.1 JSON-RPC Server
- [ ] HTTP/WebSocket server
- [ ] Standard eth_* methods
- [ ] web3_* methods
- [ ] net_* methods
- [ ] debug_* methods (optional)
- [ ] trace_* methods (optional)
- **Issues**: #26, #27, #28

#### 4.2 CLI & Configuration
- [ ] Command-line interface
- [ ] Configuration file support
- [ ] Network selection
- [ ] Logging configuration
- [ ] Metrics export
- **Issues**: #29, #30

#### 4.3 Documentation & Examples
- [ ] API documentation
- [ ] Integration examples
- [ ] Deployment guides
- [ ] Performance tuning guide
- **Issues**: #31, #32

**Deliverable**: A production-ready client with full Web3 compatibility

---

## Phase 5: Optimization & Advanced Features (2026)

**Goal**: Best-in-class performance and features

### Milestones

#### 5.1 Performance Optimization
- [ ] Parallel transaction execution
- [ ] Optimized trie operations
- [ ] SIMD cryptographic operations
- [ ] Memory pooling
- [ ] Zero-copy deserialization
- **Issues**: #33, #34, #35

#### 5.2 Advanced Features
- [ ] Light client support
- [ ] Archive node mode
- [ ] State snapshots
- [ ] GraphQL endpoint
- [ ] Prometheus metrics
- [ ] Distributed tracing
- **Issues**: #36, #37, #38

#### 5.3 EIP Support
- [ ] EIP-1559 (dynamic fees) ✅ (in progress)
- [ ] EIP-2930 (access lists)
- [ ] EIP-4844 (proto-danksharding)
- [ ] EIP-4895 (beacon chain withdrawals)
- [ ] Future EIPs as they're finalized
- **Issues**: #39, #40, #41

**Deliverable**: Industry-leading Ethereum client

---

## Long-term Vision (2027+)

### Community & Ecosystem
- [ ] Active Discord community (1000+ members)
- [ ] Regular contributor meetups
- [ ] Bug bounty program
- [ ] Academic partnerships
- [ ] Conference presentations

### Production Adoption
- [ ] 100+ nodes running Zeth on mainnet
- [ ] Used by DApp developers
- [ ] Integration with major Ethereum tools
- [ ] Listed on ethereum.org
- [ ] Production deployments at scale

### Research & Innovation
- [ ] Novel optimization techniques
- [ ] Research papers on Zig for blockchain
- [ ] Collaboration with Ethereum Foundation
- [ ] zkEVM integration
- [ ] Cross-chain bridges

---

## Success Metrics

### Short-term (2025)
- ✅ 14 tests passing (achieved)
- [ ] 500+ tests passing
- [ ] Sync Sepolia testnet
- [ ] 10+ regular contributors
- [ ] 100+ GitHub stars

### Medium-term (2026)
- [ ] Full mainnet sync
- [ ] 1000+ tests passing
- [ ] <2GB memory usage for full node
- [ ] 50+ contributors
- [ ] 1000+ GitHub stars
- [ ] Featured in Ethereum client diversity discussions

### Long-term (2027+)
- [ ] 5%+ client diversity share
- [ ] Production deployments
- [ ] Sub-second block processing
- [ ] Active development community
- [ ] Referenced in academic research

---

## How to Help

### Immediate Needs
1. **Cryptography experts**: Implement proper Keccak-256 and secp256k1
2. **EVM specialists**: Expand opcode coverage
3. **Network engineers**: Build DevP2P implementation
4. **Zig enthusiasts**: Code review and optimization
5. **Technical writers**: Documentation and tutorials

### Ways to Contribute
- Pick an issue from the GitHub project board
- Submit bug reports and feature requests
- Review pull requests
- Write tests and documentation
- Share Zeth in your communities

### Community Building
- Star the repository
- Share on Twitter, Hacker News, Discord
- Write blog posts about your experience
- Present at meetups and conferences
- Help answer questions in discussions

---

## Dependencies & Compatibility

### Zig Evolution
We track Zig releases closely and aim to support:
- Current stable release (0.15.1)
- Latest development version
- Update within 1 week of new Zig releases

### Ethereum Evolution
We implement EIPs based on:
- Finalized EIPs: Implemented before activation
- Proposed EIPs: Tracked and prototyped
- Network upgrades: Day-1 compatibility

---

## Governance

### Decision Making
- **Technical decisions**: Consensus among maintainers
- **Major features**: Community RFC process
- **Breaking changes**: Discussed in GitHub Discussions
- **Security**: Fast-tracked with immediate review

### Maintainer Responsibilities
- Code review within 48 hours
- Release management
- Community engagement
- Direction setting
- Security response

---

## Release Schedule

### Versioning
We follow [Semantic Versioning](https://semver.org/):
- **Major**: Breaking changes
- **Minor**: New features, backward compatible
- **Patch**: Bug fixes

### Planned Releases
- **v0.1.0** (Jan 2025): Foundation ✅
- **v0.2.0** (Apr 2025): Complete EVM
- **v0.3.0** (Jul 2025): Network sync
- **v0.4.0** (Oct 2025): Full node
- **v1.0.0** (Dec 2025): Production ready

---

## Contact & Community

- **GitHub**: https://github.com/SMC17/eth-zig
- **Issues**: https://github.com/SMC17/eth-zig/issues
- **Discussions**: https://github.com/SMC17/eth-zig/discussions
- **Twitter**: Coming soon
- **Discord**: Coming soon

---

**Let's build the future of Ethereum infrastructure together!** 🚀

*Last updated: October 29, 2025*

