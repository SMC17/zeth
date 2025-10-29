# Zeth - Ethereum Implementation in Zig

[![CI Status](https://github.com/SMC17/eth-zig/workflows/CI/badge.svg)](https://github.com/SMC17/eth-zig/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Zig](https://img.shields.io/badge/Zig-0.15.1-orange.svg)](https://ziglang.org/)

> **Building the most advanced, optimized, performant, and secure Ethereum implementation in Zig**

A modern Ethereum protocol implementation written in Zig, designed to be the go-to integration layer for the Ethereum ecosystem. We leverage Zig's safety guarantees, performance characteristics, and compile-time execution to build a client that's both fast and reliable.

## 🎯 Vision

Zeth aims to become the reference implementation for Ethereum in Zig, providing:
- **Performance**: Sub-second block processing with minimal memory footprint
- **Safety**: Compile-time guarantees and explicit error handling
- **Clarity**: Clean, readable code that serves as documentation
- **Community**: Open, welcoming, and collaborative development

## ⚠️ Project Status: Alpha (v0.1.0)

**Current State**: Early development, NOT production-ready

We're being completely transparent: Zeth is in its infancy. We have the foundation, but we need YOUR help to build this into a production-ready client.

### What Works ✅
- Core data structures (Address, Hash, U256, Transaction, Block, Account)
- RLP encoding/decoding
- Basic EVM (~15/150+ opcodes)
- State management with Merkle Patricia Trie
- 14 passing tests, 1,351 lines of code

### What's Missing ❌
- Complete cryptography (proper Keccak-256, full secp256k1)
- Full EVM implementation (135+ more opcodes)
- P2P networking (DevP2P, RLPx)
- Consensus mechanisms (Proof of Stake)
- JSON-RPC API
- Database persistence
- Real-world testing at scale

**We need contributors!** See [CONTRIBUTING.md](CONTRIBUTING.md) and [ROADMAP.md](ROADMAP.md)

## Features Implemented

- Core data structures (Address, Hash, U256, Block, Transaction)
- Cryptographic primitives (Keccak256 hashing)
- RLP (Recursive Length Prefix) encoding/decoding
- EVM (Ethereum Virtual Machine) with basic opcodes
- State management with Merkle Patricia Trie
- Account and storage management

## Architecture

```
src/
├── main.zig           # Entry point
├── types/
│   └── types.zig      # Core Ethereum types
├── crypto/
│   └── crypto.zig     # Cryptographic functions
├── rlp/
│   └── rlp.zig        # RLP encoding/decoding
├── evm/
│   └── evm.zig        # Ethereum Virtual Machine
└── state/
    └── state.zig      # State management and trie
```

## Building

Requires Zig 0.13.0 or later.

```bash
# Build the project
zig build

# Run the node
zig build run

# Run tests
zig build test
```

## Components

### Core Types (`src/types/types.zig`)

- `Address`: 20-byte Ethereum address
- `Hash`: 32-byte hash
- `U256`: 256-bit unsigned integer
- `Transaction`: Ethereum transaction structure
- `Block`: Block structure with header and transactions
- `Account`: Account state

### Cryptography (`src/crypto/crypto.zig`)

- Keccak256 hashing (SHA3-256 as placeholder)
- secp256k1 signatures (placeholder)
- Public key to address conversion

### RLP Encoding (`src/rlp/rlp.zig`)

- Encode bytes, integers, and lists
- Decode RLP-encoded data
- Support for short and long form encoding

### EVM (`src/evm/evm.zig`)

- Stack machine with 1024 depth limit
- Memory and storage management
- Basic opcodes: ADD, MUL, SUB, DIV, PUSH, POP, MLOAD, MSTORE, SLOAD, SSTORE, JUMP, JUMPI, RETURN
- Gas metering

### State Management (`src/state/state.zig`)

- Account state database
- Storage key-value mapping
- Merkle Patricia Trie (basic implementation)
- Balance and nonce management

## Roadmap

### Phase 1: Core Infrastructure (Current)
- [x] Basic types and data structures
- [x] RLP encoding/decoding
- [x] Basic EVM implementation
- [x] State management
- [ ] Complete cryptographic implementations

### Phase 2: Networking
- [ ] DevP2P protocol implementation
- [ ] Peer discovery (Kademlia DHT)
- [ ] RLPx transport protocol
- [ ] ETH wire protocol

### Phase 3: Consensus
- [ ] Block validation
- [ ] Transaction pool
- [ ] Proof of Stake (Casper FFG)
- [ ] Sync protocols

### Phase 4: APIs
- [ ] JSON-RPC server
- [ ] Web3 API compatibility
- [ ] GraphQL endpoint
- [ ] WebSocket support

### Phase 5: Storage
- [ ] LevelDB integration
- [ ] State pruning
- [ ] Snapshot sync
- [ ] Archive node support

## 🚀 Quick Start

```bash
# Clone the repository
git clone https://github.com/SMC17/eth-zig.git
cd eth-zig

# Build the project
zig build

# Run tests
zig build test

# Run the example
zig build run
```

### Example Output
```
Zeth - Ethereum Implementation in Zig
======================================

Transaction created:
  Nonce: 0
  Gas Price: 20000000000
  Gas Limit: 21000
  Value: 1000000000000000000 wei

Keccak256 hash of "Hello, Ethereum!":
  0x3c152fae473600fa75a2205ff7110142a89ebe9751b7e28bf1684067454533ab
```

## 🧪 Testing

Run the full test suite:
```bash
zig build test    # All 14 tests should pass
```

Individual component tests:
```bash
zig test src/types/types.zig   # Core types
zig test src/crypto/crypto.zig # Cryptography
zig test src/rlp/rlp.zig       # RLP encoding
zig test src/evm/evm.zig       # EVM
zig test src/state/state.zig   # State management
```

## 🤝 Contributing

**We need YOUR help!** Zeth is a community-driven project and we welcome contributions of all kinds.

### Immediate Needs
- 🔐 **Cryptography**: Implement proper Keccak-256 and complete secp256k1
- ⚡ **EVM**: Expand opcode coverage from 15 to 150+
- 🌐 **Networking**: Build DevP2P and RLPx protocols
- 🧪 **Testing**: Add more comprehensive tests
- 📚 **Documentation**: Write tutorials and guides

### How to Contribute
1. Check out [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines
2. Look at [good first issues](https://github.com/SMC17/eth-zig/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22)
3. Join discussions in [GitHub Discussions](https://github.com/SMC17/eth-zig/discussions)
4. Submit PRs, report bugs, suggest features!

Read our [ROADMAP.md](ROADMAP.md) to see where we're headed.

## 📖 Documentation

- [ROADMAP.md](ROADMAP.md) - Project roadmap and milestones
- [CONTRIBUTING.md](CONTRIBUTING.md) - How to contribute
- [IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md) - Detailed feature status
- [Ethereum Yellow Paper](https://ethereum.github.io/yellowpaper/paper.pdf) - Ethereum specification

## 🎯 Why Zig for Ethereum?

- **Memory Safety**: Compile-time checks prevent common vulnerabilities
- **Performance**: No hidden control flow, explicit allocations
- **Simplicity**: No hidden memory management, clear error handling
- **Cross-platform**: Easy compilation to any target
- **Compile-time Execution**: Powerful metaprogramming without macros

## 🌟 Star History

If you find Zeth interesting, give us a star! It helps us grow the community.

## 💬 Community

- **GitHub Issues**: [Report bugs & request features](https://github.com/SMC17/eth-zig/issues)
- **GitHub Discussions**: [Ask questions & share ideas](https://github.com/SMC17/eth-zig/discussions)
- **Twitter**: Coming soon - follow for updates
- **Discord**: Coming soon - join for real-time chat

## 📄 License

MIT License - See [LICENSE](LICENSE) for details

## ⚠️ Disclaimer

**This is alpha software under active development.**

- NOT production-ready
- NOT audited for security
- APIs will change
- Do NOT use with real funds
- Use at your own risk

This is an educational and experimental project. We're building in public and learning together.

## 🙏 Acknowledgments

Inspired by:
- [go-ethereum (Geth)](https://github.com/ethereum/go-ethereum) - The reference Ethereum implementation
- [Reth](https://github.com/paradigmxyz/reth) - Rust Ethereum implementation
- [Zig](https://ziglang.org/) - The Zig programming language

Special thanks to the Ethereum Foundation and Zig community.

---

**Built with ❤️ by the Zeth community**

[⭐ Star us on GitHub](https://github.com/SMC17/eth-zig) | [🐛 Report a Bug](https://github.com/SMC17/eth-zig/issues/new?template=bug_report.md) | [💡 Request a Feature](https://github.com/SMC17/eth-zig/issues/new?template=feature_request.md)

