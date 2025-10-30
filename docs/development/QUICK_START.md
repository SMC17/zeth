# Quick Start Guide

**New to Zeth? Start here!**

## For Developers

1. **Clone and Build**
   ```bash
   git clone https://github.com/SMC17/zeth.git
   cd zeth
   zig build
   ```

2. **Run Tests**
   ```bash
   zig build test
   ```

3. **Try Examples**
   ```bash
   zig build run-counter
   ```

4. **Start Contributing**
   - Read [CONTRIBUTING.md](CONTRIBUTING.md)
   - Check [EVM Parity Status](docs/architecture/EVM_PARITY_STATUS.md)
   - Pick an unimplemented opcode
   - Submit a PR!

## For Learners

1. **Read the Code**
   - Start with `src/evm/evm.zig`
   - Follow opcode implementations
   - Check examples in `examples/`

2. **Learn Zig**
   - [Official Docs](https://ziglang.org/documentation/)
   - [Zig Learn](https://ziglearn.org/)

3. **Learn EVM**
   - [Ethereum Docs](https://ethereum.org/en/developers/)
   - [Yellow Paper](https://ethereum.github.io/yellowpaper/paper.pdf)
   - [EVM Opcodes](https://ethereum.org/en/developers/docs/evm/opcodes/)

## For Researchers

1. **Explore Architecture**
   - [ARCHITECTURE.md](docs/architecture/ARCHITECTURE.md)
   - Module structure
   - Design decisions

2. **Run Validation**
   ```bash
   zig build validate-rlp
   ./zig-out/bin/run_reference_tests
   ```

3. **Contribute Research**
   - Open a Discussion
   - Share findings
   - Propose improvements

---

**Questions?** Open a [Discussion](https://github.com/SMC17/zeth/discussions) or check the [docs](docs/)!
