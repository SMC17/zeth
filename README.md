# Zeth - Ethereum Virtual Machine in Zig

[![CI Status](https://github.com/SMC17/eth-zig/workflows/CI/badge.svg)](https://github.com/SMC17/eth-zig/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Zig](https://img.shields.io/badge/Zig-0.15.1-orange.svg)](https://ziglang.org/)
[![RLP Validated](https://img.shields.io/badge/RLP-98.8%25%20Ethereum%20Validated-green)](https://github.com/SMC17/eth-zig)

**A production-grade Ethereum Virtual Machine implementation in Zig, designed for learning, development, and research.**

---

## Vision

Zeth aims to be:

- **Educational**: Learn Zig and EVM through clear, well-documented code
- **Validated**: Tested against Ethereum's official test suite
- **Extensible**: Modular design for research and development
- **Foundation**: Base layer for Ethereum ecosystem tools in Zig
- **Bridge**: Connect Zig and Ethereum developer communities

---

## Current Status

### Implementation Progress

- **Opcodes Implemented**: ~70/256 (~27%)
- **Opcodes Validated**: 11/256 (100% passing reference tests)
- **RLP**: 98.8% Ethereum validated (82/83 tests)
- **Test Coverage**: 95+ internal tests, 100% passing

### What Works

- Core arithmetic and comparison operations  
- Stack operations (PUSH, DUP, SWAP)  
- Memory and storage operations (with EIP-2929)  
- Flow control (JUMP, JUMPI)  
- Environmental and block information  
- Logging operations  
- Reference implementation comparison framework  

### In Progress

- Complete opcode implementation (~170 remaining)  
- Full Ethereum test suite integration  
- Gas cost verification for all opcodes  
- Performance optimization  

**Target**: 100% opcode parity within 6-8 weeks

---

## Quick Start

### Prerequisites

- **Zig 0.15.1**: [Download](https://ziglang.org/download/)
- **Python 3.11+** (optional, for validation tools)

### Installation

```bash
git clone https://github.com/SMC17/eth-zig.git
cd zeth
zig build
```

### Run Examples

```bash
# Counter contract
zig build run-counter

# Storage operations
zig build run-storage

# Arithmetic operations
zig build run-arithmetic

# Event logging
zig build run-events
```

### Testing

```bash
# Run all tests
zig build test

# Validate against Ethereum tests
zig build validate-rlp
zig build validate-rlp-decode
zig build validate-rlp-invalid

# Reference comparison (requires PyEVM)
pip3 install eth-py-evm
zig build
./zig-out/bin/run_reference_tests
```

---

## Documentation

- **[Architecture](docs/architecture/ARCHITECTURE.md)** - System design and components
- **[EVM Parity Status](docs/architecture/EVM_PARITY_STATUS.md)** - Implementation progress
- **[Strategic Roadmap](docs/architecture/STRATEGIC_ROADMAP.md)** - Long-term vision and blockchain path
- **[Implementation Plan](docs/internal/IMPLEMENTATION_PLAN.md)** - Detailed development phases
- **[Getting Started](docs/development/GETTING_STARTED.md)** - Developer guide
- **[Contributing](CONTRIBUTING.md)** - How to contribute
- **[Roadmap](docs/community/PROJECT_ROADMAP.md)** - Project vision and timeline

---

## Project Structure

```
zeth/
├── src/
│   ├── types/        # U256, Address, Hash
│   ├── crypto/       # Cryptographic primitives
│   ├── rlp/          # RLP encoding/decoding (98.8% validated)
│   ├── evm/          # EVM virtual machine
│   └── state/        # State management
├── examples/          # Example contracts
├── validation/       # Testing and validation tools
└── docs/             # Documentation
```

---

## Validation & Testing

### RLP Implementation: 98.8% Validated

- **Encoding**: 28/28 tests (100%)
- **Decoding**: 28/28 tests (100%)
- **Security**: 25/26 tests (96.2%)
- **Total**: 82/83 official Ethereum tests passing

### Reference Implementation Comparison

- **PyEVM**: Integrated, 11/11 critical opcodes validated
- **Geth**: Setup in progress

### Test Coverage

- **Internal Tests**: 95+ tests, 100% passing
- **Ethereum RLP Tests**: 82/83 passing
- **Reference Comparison**: 11 critical opcodes validated

---

## Why Zig for Ethereum?

### Memory Safety
- Compile-time checks prevent vulnerabilities
- Explicit memory management
- No undefined behavior

### Performance
- Zero-cost abstractions
- No garbage collector
- Optimized compilation

### Simplicity
- Clear, readable code
- No hidden control flow
- Predictable execution

### Cross-Platform
- Easy cross-compilation
- Native performance everywhere
- Minimal dependencies

---

## Contributing

We welcome contributions! Priority areas:

1. **Missing Opcodes**: See [EVM Parity Status](docs/architecture/EVM_PARITY_STATUS.md)
2. **Documentation**: Guides, tutorials, examples
3. **Testing**: Edge cases, fuzzing, integration tests
4. **Performance**: Optimization, benchmarking

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

---

## Roadmap

### Phase 1: Foundation (Weeks 1-4)
- Core EVM implementation
- RLP validation
- Reference comparison framework
- Repository professionalization

### Phase 2: Parity (Weeks 5-8)
- Complete opcode implementation
- Full test suite integration
- Gas cost verification
- Performance optimization

### Phase 3: Ecosystem (Months 2-4)
- JSON-RPC interface
- Development tools
- Educational resources
- Community building

See [Roadmap](docs/community/PROJECT_ROADMAP.md) for details.

---

## Status Disclaimer

**This is alpha software under active development.**

- RLP: Ethereum validated (98.8%)
- EVM: Implementation in progress (~30% complete)
- Not production ready
- Not audited
- Do not use with real funds

We validate systematically. We launch with proof.

---

## License

MIT License - See [LICENSE](LICENSE)

---

## Acknowledgments

- [Ethereum Foundation](https://ethereum.org) - Specifications and test vectors
- [go-ethereum](https://github.com/ethereum/go-ethereum) - Reference implementation
- [PyEVM](https://github.com/ethereum/py-evm) - Python reference
- [Zig](https://ziglang.org/) - The programming language

---

## Get Involved

- **Star** the repository
- **Report** bugs via [Issues](https://github.com/SMC17/eth-zig/issues)
- **Discuss** in [Discussions](https://github.com/SMC17/eth-zig/discussions)
- **Contribute** code or documentation
- **Share** with Zig and Ethereum communities

---

**Building systematically. Validating thoroughly. Launching with proof.**

**Repository**: https://github.com/SMC17/eth-zig  
**Status**: v0.3.0-alpha (Week 4 - Professionalization)  
**Goal**: 100% EVM parity (6-8 weeks)
