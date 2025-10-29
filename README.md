# Zeth - Ethereum Implementation in Zig

A modern, high-performance Ethereum protocol implementation written in Zig.

## Project Status

This is an early-stage implementation of the Ethereum protocol in Zig. The project aims to provide a clean, efficient, and well-documented Ethereum node implementation.

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

## Testing

Run the test suite:

```bash
zig build test
```

Individual component tests:

```bash
# Test crypto module
zig test src/crypto/crypto.zig

# Test RLP module
zig test src/rlp/rlp.zig

# Test EVM
zig test src/evm/evm.zig

# Test state management
zig test src/state/state.zig
```

## References

- [Ethereum Yellow Paper](https://ethereum.github.io/yellowpaper/paper.pdf)
- [go-ethereum (Geth)](https://github.com/ethereum/go-ethereum)
- [Zig Language Reference](https://ziglang.org/documentation/master/)

## Contributing

Contributions are welcome! This is an educational and experimental project.

## License

MIT License - See LICENSE file for details

## Disclaimer

This is an experimental implementation for educational purposes. Do not use in production or with real funds.

