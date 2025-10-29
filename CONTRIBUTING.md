# Contributing to Zeth

First off, thank you for considering contributing to Zeth! It's people like you that will make Zeth the best Ethereum implementation in Zig.

## Vision

Zeth aims to be the most advanced, optimized, performant, and secure Ethereum implementation. We're building this as a community-driven project that evolves alongside both Zig and Ethereum.

## Code of Conduct

This project and everyone participating in it is governed by our commitment to fostering an open and welcoming environment. We pledge to make participation in our project a harassment-free experience for everyone.

## How Can I Contribute?

### Reporting Bugs

Before creating bug reports, please check the existing issues to avoid duplicates. When creating a bug report, include:

- **Clear title and description**
- **Steps to reproduce** the problem
- **Expected vs actual behavior**
- **Zig version** (`zig version`)
- **OS and architecture**
- **Code samples** if applicable

### Suggesting Enhancements

Enhancement suggestions are tracked as GitHub issues. When creating an enhancement suggestion:

- **Use a clear and descriptive title**
- **Provide a detailed description** of the proposed functionality
- **Explain why this enhancement would be useful**
- **List any similar implementations** in other Ethereum clients

### Pull Requests

1. **Fork the repo** and create your branch from `main`
2. **Follow the Zig style guide**: Use `zig fmt` on all code
3. **Add tests** for new functionality
4. **Update documentation** including comments and README
5. **Ensure all tests pass** with `zig build test`
6. **Write clear commit messages**

#### Commit Message Format

```
<type>: <subject>

<body>

<footer>
```

Types: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`

Example:
```
feat: add EIP-1559 transaction support

Implement dynamic fee transactions with base fee and priority fee.
Includes validation and RLP encoding.

Closes #42
```

## Development Setup

```bash
# Clone your fork
git clone https://github.com/YOUR_USERNAME/eth-zig.git
cd eth-zig

# Verify Zig version
zig version  # Should be 0.15.1 or later

# Build and test
zig build
zig build test
zig build run
```

## Project Structure

```
src/
├── main.zig          # Entry point and examples
├── types/            # Core Ethereum types
├── crypto/           # Cryptographic primitives
├── rlp/              # RLP encoding/decoding
├── evm/              # Ethereum Virtual Machine
├── state/            # State management
├── network/          # P2P networking (TODO)
├── consensus/        # Consensus logic (TODO)
└── rpc/              # JSON-RPC API (TODO)
```

## Coding Standards

### Zig Style
- Run `zig fmt` on all files
- Use descriptive variable names
- Document all public APIs with `///` doc comments
- Keep functions focused and under 100 lines when possible
- Use explicit error sets

### Testing
- Write tests for all new functionality
- Aim for >80% code coverage
- Include both unit and integration tests
- Test edge cases and error conditions

### Documentation
- Document all public functions and types
- Include usage examples in doc comments
- Update README.md for user-facing changes
- Update IMPLEMENTATION_STATUS.md for feature progress

## Areas Needing Help

We need contributors in these areas (see issues for specifics):

### High Priority
- **Cryptography**: Complete secp256k1 and Keccak-256 implementations
- **EVM**: Expand opcode coverage (currently ~15/150+ opcodes)
- **Testing**: More comprehensive test coverage
- **Performance**: Benchmarking and optimization

### Medium Priority
- **Networking**: DevP2P and RLPx protocol implementation
- **Storage**: Database integration (LevelDB/RocksDB)
- **JSON-RPC**: Web3-compatible API server
- **Consensus**: Proof of Stake implementation

### Lower Priority
- **Documentation**: More examples and tutorials
- **Tooling**: Better CLI and configuration
- **Monitoring**: Metrics and observability
- **Compatibility**: Test against Ethereum test vectors

## Performance Guidelines

- Profile before optimizing
- Prefer clarity over premature optimization
- Use `@setRuntimeSafety(false)` only in hot paths
- Document performance-critical sections
- Include benchmarks for optimization PRs

## Security

### Reporting Security Issues

**Do not open public issues for security vulnerabilities.**

Email security concerns to: [Will be added - please create a security email]

Include:
- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if any)

### Security Review Checklist
- [ ] No unsafe memory operations
- [ ] Proper error handling
- [ ] Input validation
- [ ] No integer overflows
- [ ] Cryptographic operations use vetted libraries
- [ ] No hardcoded secrets

## Communication

- **GitHub Issues**: Bug reports, features, discussions
- **GitHub Discussions**: General questions, ideas
- **Discord** (coming soon): Real-time chat
- **Twitter** (coming soon): Announcements

## Recognition

All contributors will be:
- Listed in CONTRIBUTORS.md
- Mentioned in release notes
- Credited in relevant documentation

Significant contributors may be invited to become maintainers.

## Getting Help

- Read the [README.md](README.md) and [IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md)
- Check existing issues and discussions
- Ask questions in GitHub Discussions
- Join our Discord (coming soon)

## License

By contributing, you agree that your contributions will be licensed under the MIT License.

## References

Useful resources for contributors:

- [Ethereum Yellow Paper](https://ethereum.github.io/yellowpaper/paper.pdf)
- [Ethereum EIPs](https://eips.ethereum.org/)
- [go-ethereum (Geth)](https://github.com/ethereum/go-ethereum)
- [Zig Language Reference](https://ziglang.org/documentation/master/)
- [Zig Style Guide](https://ziglang.org/documentation/master/#Style-Guide)

---

Thank you for contributing to Zeth! 🚀

