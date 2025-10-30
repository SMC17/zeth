# Zeth Architecture

**Status**: Work in Progress  
**Last Updated**: January 2025

## Overview

Zeth is a production-grade Ethereum Virtual Machine implementation in Zig, designed to be:

- **Validated**: Tested against Ethereum's official test suite
- **Extensible**: Modular design for research and development
- **Educational**: Clear codebase for learning Zig and EVM
- **Foundation**: Base layer for Ethereum ecosystem tools

## Core Components

### 1. Types (`src/types/`)
- `U256`: 256-bit unsigned integers
- `Address`: 20-byte Ethereum addresses
- `Hash`: 32-byte hashes
- All types include edge case handling and validation

### 2. Crypto (`src/crypto/`)
- Keccak-256 hashing (SHA3)
- Cryptographic primitives
- Foundation for address generation and signatures

### 3. RLP (`src/rlp/`)
- **Status**: 98.8% Ethereum validated (82/83 tests passing)
- Encoding and decoding of recursive-length prefix data
- Security hardened through systematic testing
- Used for transaction and block serialization

### 4. EVM (`src/evm/`)
- Virtual machine core
- 80+ opcodes implemented
- Gas metering (EIP-2929, EIP-2200)
- Stack, memory, and storage management
- **Validation**: In progress via PyEVM comparison

### 5. State (`src/state/`)
- Account state management
- Storage trie operations
- Balance tracking
- Future: Full state tree implementation

## Design Principles

1. **Memory Safety**: Leverage Zig's compile-time checks
2. **Explicit Allocation**: Clear ownership and lifecycle management
3. **Test-Driven**: Validate against Ethereum ground truth
4. **Modularity**: Independent, reusable components
5. **Documentation**: Clear code and comprehensive guides

## Current Status

###  Complete
- RLP encoding/decoding (validated)
- Core EVM opcodes (80+)
- Basic state management
- Validation framework

###  In Progress
- EVM opcode validation against Ethereum tests
- Gas cost verification
- Complete state tree implementation
- Advanced opcodes (CALL variants, CREATE2)

###  Planned
- JSON-RPC interface
- Full blockchain state management
- Network layer (devp2p)
- Consensus mechanisms
- Performance optimizations

## Extensibility

Zeth is designed as a foundation layer. Potential extensions:

- **Research**: Experiment with new EVM features
- **Tools**: Build development and testing tools
- **Clients**: Full Ethereum clients
- **Layer 2s**: Custom execution environments
- **Educational**: Learn-by-reading implementation

## Branching Strategy

- **main**: Stable, validated releases
- **develop**: Integration branch
- **feature/***: New features
- **research/***: Experimental work
- **parity/***: EVM specification compliance

