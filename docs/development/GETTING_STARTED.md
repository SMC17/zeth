# Getting Started with Zeth

Welcome to Zeth! This guide will help you get started with developing and contributing.

## Prerequisites

- **Zig 0.15.1**: Download from [ziglang.org](https://ziglang.org/)
- **Python 3.11+**: For validation tools (optional)
- **Git**: For version control

## Quick Start

```bash
# Clone the repository
git clone https://github.com/YOUR_USERNAME/zeth.git
cd zeth

# Build the project
zig build

# Run tests
zig build test

# Run examples
zig build run-counter
zig build run-storage
zig build run-arithmetic
zig build run-events
```

## Project Structure

```
zeth/
├── src/              # Core implementation
│   ├── types/        # U256, Address, Hash types
│   ├── crypto/       # Cryptographic primitives
│   ├── rlp/          # RLP encoding/decoding
│   ├── evm/          # EVM virtual machine
│   └── state/        # State management
├── examples/         # Example contracts
├── validation/       # Testing and validation tools
└── docs/             # Documentation
```

## Development Workflow

1. **Pick a task**: Check [EVM_PARITY_STATUS.md](../architecture/EVM_PARITY_STATUS.md) for missing opcodes
2. **Create a branch**: `git checkout -b feature/opcode-name`
3. **Implement**: Follow existing code patterns
4. **Test**: Add tests in the relevant module
5. **Validate**: Run `zig build test` and reference comparison
6. **Submit PR**: With clear description

## Code Style

- Follow Zig conventions
- Use `zig fmt` before committing
- Add tests for new functionality
- Document public APIs

## Testing

```bash
# Run all tests
zig build test

# Validate against Ethereum tests
zig build validate-rlp
zig build validate-rlp-decode
zig build validate-rlp-invalid

# Run reference comparison (requires PyEVM)
zig build
./zig-out/bin/run_reference_tests
```

## Learning Resources

- [Zig Documentation](https://ziglang.org/documentation/)
- [Ethereum Yellow Paper](https://ethereum.github.io/yellowpaper/paper.pdf)
- [EVM Opcodes](https://ethereum.org/en/developers/docs/evm/opcodes/)
- [EIPs](https://eips.ethereum.org/)

## Getting Help

- Open an issue for bugs
- Start a discussion for questions
- Check existing documentation
- Review code examples

Happy coding!

