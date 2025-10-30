# Contributing to Zeth

Thank you for your interest in contributing to Zeth! This document provides guidelines for contributing code, documentation, tests, and ideas.

## How to Contribute

### Reporting Bugs

Use the [Bug Report template](.github/ISSUE_TEMPLATE/bug_report.md) when opening an issue. Include:

- Clear description of the bug
- Steps to reproduce
- Expected vs actual behavior
- Environment details (Zig version, OS, etc.)

### Suggesting Features

Use the [Feature Request template](.github/ISSUE_TEMPLATE/feature_request.md). Explain:

- The problem you're solving
- Proposed solution
- Alternative approaches considered

### Implementing Opcodes

See the [Opcode Implementation template](.github/ISSUE_TEMPLATE/opcode_implementation.md). Priority areas:

1. **Copy Operations**: CALLDATACOPY, CODECOPY, RETURNDATACOPY, EXTCODECOPY
2. **Signed Operations**: SDIV, SMOD, SIGNEXTEND
3. **External Operations**: BALANCE, EXTCODESIZE, EXTCODEHASH
4. **Block Info**: BLOCKHASH, SELFBALANCE

Check [EVM Parity Status](docs/architecture/EVM_PARITY_STATUS.md) for current status.

## Development Workflow

### 1. Fork and Clone

```bash
git clone https://github.com/YOUR_USERNAME/zeth.git
cd zeth
```

### 2. Create a Branch

```bash
git checkout -b feature/your-feature-name
# or
git checkout -b opcode/opcode-name
# or
git checkout -b fix/bug-description
```

### 3. Make Changes

- Follow existing code patterns
- Add tests for new functionality
- Update documentation
- Run `zig fmt` before committing

### 4. Test Your Changes

```bash
# Run all tests
zig build test

# Validate RLP if modified
zig build validate-rlp

# Reference comparison if adding opcodes
./zig-out/bin/run_reference_tests
```

### 5. Commit

Use clear, descriptive commit messages:

```
feat: implement CALLDATACOPY opcode
fix: correct gas cost for EXP operation
docs: add example for storage operations
test: add edge case tests for MLOAD
```

### 6. Push and Create PR

```bash
git push origin feature/your-feature-name
```

Then open a Pull Request on GitHub with:
- Clear description
- Reference to related issues
- Test results
- Any breaking changes

## Code Style

### Zig Conventions

- Use `zig fmt` for formatting
- Follow Zig naming conventions
- Add doc comments for public APIs
- Use explicit error handling

### Code Organization

- Keep functions focused and small
- Use descriptive names
- Add comments for complex logic
- Match existing patterns

### Testing

- Add tests for all new functionality
- Test edge cases
- Validate against reference implementations
- Update test counts in documentation

## Implementation Guidelines

### Adding an Opcode

1. **Add to enum**: `src/evm/evm.zig` - `Opcode` enum
2. **Add to switch**: `executeOpcode` function
3. **Implement**: Create `opOpcodeName` function
4. **Test**: Add tests in relevant test files
5. **Validate**: Add to reference comparison
6. **Document**: Update parity status

### Example

```zig
// In Opcode enum
SOMEOPCODE = 0xXX,

// In executeOpcode switch
.SOMEOPCODE => try self.opSomeOpcode(),

// Implementation
fn opSomeOpcode(self: *EVM) !void {
    // Implementation
    const value = try self.stack.pop();
    // ... logic ...
    try self.stack.push(self.allocator, result);
    self.gas_used += GAS_COST;
}
```

## Validation Requirements

### For Opcodes

- [ ] Unit tests passing
- [ ] Gas cost verified against Yellow Paper
- [ ] Reference implementation comparison (if available)
- [ ] Edge cases tested
- [ ] Documentation updated

### For Core Features

- [ ] Tests added
- [ ] Documentation updated
- [ ] Examples updated (if applicable)
- [ ] Performance considered

## Getting Help

- **Questions**: Open a [Discussion](https://github.com/SMC17/zeth/discussions)
- **Bugs**: Open an [Issue](https://github.com/SMC17/zeth/issues)
- **Code Review**: Wait for maintainer feedback on PRs

## Code of Conduct

- Be respectful and inclusive
- Focus on constructive feedback
- Help others learn
- Follow the project's goals

## Recognition

Contributors will be:

- Listed in [CONTRIBUTORS.md](docs/community/CONTRIBUTORS.md)
- Credited in release notes
- Acknowledged in documentation

Thank you for contributing to Zeth!
