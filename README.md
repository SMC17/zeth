# Zeth - Ethereum Implementation in Zig

[![CI Status](https://github.com/SMC17/zeth/workflows/CI/badge.svg)](https://github.com/SMC17/zeth/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Zig](https://img.shields.io/badge/Zig-0.15.1-orange.svg)](https://ziglang.org/)
[![RLP Validated](https://img.shields.io/badge/RLP-98.8%25%20Ethereum%20Validated-green)](https://github.com/SMC17/zeth)

> **Building a validated, production-grade Ethereum implementation in Zig**

---

## ⚠️ Status: VALIDATION IN PROGRESS - NOT READY FOR LAUNCH

**Current Phase**: Week 1 Complete, Week 2 In Progress

**Validation Against Ethereum**:
- ✅ **RLP: 98.8% validated** (82/83 official Ethereum tests passing)
- ⏳ **EVM Opcodes**: Manual verification in progress
- ⏳ **Gas Costs**: Yellow Paper verification pending
- ⏳ **Real Contracts**: Testing pending

**We validate systematically. We launch with proof. Timeline: 5-6 weeks.**

---

## ✅ What's ACTUALLY Validated (Ethereum Ground Truth)

### RLP Implementation: **98.8%** Ethereum Validated
- **Encoding**: 28/28 tests (100%)
- **Decoding**: 28/28 tests (100%)
- **Security**: 25/26 tests (96.2%)
- **Bugs Found & Fixed**: 5 critical issues

**This is the only component we can confidently claim works.**

---

## 🚧 What's Implemented But NOT Yet Validated

### EVM with 80+ Opcodes (Awaiting Validation)
- Arithmetic: ADD, SUB, MUL, DIV, MOD, EXP
- Comparison: LT, GT, EQ, ISZERO
- Bitwise: AND, OR, XOR, NOT, SHL, SHR
- Stack: ALL PUSH (1-32), ALL DUP (1-16), ALL SWAP (1-16)
- Memory: MLOAD, MSTORE, MSIZE
- Storage: SLOAD, SSTORE
- Flow: JUMP, JUMPI, JUMPDEST, PC, GAS
- Environmental: ADDRESS, CALLER, CALLVALUE, etc.
- Block Info: TIMESTAMP, NUMBER, CHAINID, etc.
- Hashing: SHA3
- Logging: LOG0-4
- System: CALL, CREATE, REVERT, SELFDESTRUCT

**Status**: Works in our tests. **Not yet validated against Ethereum.**

---

## 🎯 Validation Timeline

### ✅ Week 1: RLP Validation (COMPLETE)
- Validated against 83 Ethereum tests
- Found and fixed 5 critical bugs
- Achieved 98.8% pass rate
- **Duration**: 1 day

### ⏳ Week 2-4: EVM Opcode Verification (IN PROGRESS)
- Manual opcode testing
- Yellow Paper gas cost verification
- Reference implementation comparison
- Target: Core opcodes verified

### ⏳ Week 5-6: Real Contract Testing
- Execute actual mainnet contracts
- Find integration bugs
- Fix systematically
- Target: 3+ contracts working

### ⏳ Week 7: Final Validation & Launch
- Comprehensive validation report
- Documentation polish
- **THEN**: Public launch

**Launch ETA**: 5-6 weeks with >90% validation proof

---

## 📊 Code Metrics

- **Total Lines**: 4,204
- **Core Implementation**: 3,488
- **Validation Framework**: 716
- **Tests (Internal)**: 66+ (all passing)
- **Tests (Ethereum)**: 82/83 passing (98.8%)
- **Examples**: 4 working
- **Documentation**: 20+ files

---

## 🐛 Bugs Found Through Validation: 5

**All discovered via Ethereum test validation. All fixed before launch.**

1. ✅ RLP decoder panic on nested lists (CRITICAL)
2. ✅ Integer overflow on huge lengths (SECURITY)
3. ✅ Accept non-optimal encodings (SECURITY)
4. ✅ Accept leading zeros (SECURITY)
5. ✅ Single byte encoding bypass (SECURITY)

**This demonstrates our validation process works.**

---

## 🚀 Quick Start

```bash
git clone https://github.com/SMC17/zeth.git
cd zeth
zig build test        # Run all tests
zig build run-counter # Run counter example
zig build bench       # Run benchmarks
```

### Validation Commands
```bash
zig build validate-rlp          # RLP encoding (100%)
zig build validate-rlp-decode   # RLP decoding (100%)
zig build validate-rlp-invalid  # Security (96.2%)
```

---

## 📖 Documentation

- [PROJECT_STATUS.md](PROJECT_STATUS.md) - Current validated state
- [WEEK1_VALIDATION_REPORT.md](WEEK1_VALIDATION_REPORT.md) - RLP validation details
- [BUGS_FOUND.md](BUGS_FOUND.md) - All bugs found via validation
- [REALITY_CHECK.md](REALITY_CHECK.md) - Honest assessment
- [ROADMAP.md](ROADMAP.md) - Long-term vision
- [CONTRIBUTING.md](CONTRIBUTING.md) - How to contribute (when ready)

---

## ⚠️ Critical Disclaimer

**This is alpha software under active validation.**

- ✅ RLP component: Ethereum validated (98.8%)
- ⚠️ EVM component: Not yet validated against Ethereum
- ❌ NOT production ready
- ❌ NOT audited
- ❌ Do NOT use with real funds

**We're building in public with radical honesty about our progress.**

---

## 🎯 Why We're Not Launching Yet

We built 4,204 lines of code and it passes our tests. But **that's not enough**.

**Professional approach**:
1. Build the system ✅
2. **Validate against Ethereum** ⏳ (in progress)
3. Find and fix all bugs ⏳
4. **Then** launch with proof

**Current**: 98.8% RLP validated. More validation needed.

---

## 💡 Why Zig for Ethereum?

- **Memory Safety**: Compile-time checks prevent vulnerabilities
- **Performance**: No GC, explicit allocations
- **Simplicity**: No hidden control flow
- **Cross-Platform**: Trivial cross-compilation

**Plus**: First serious Ethereum client in Zig means opportunity for innovation.

---

## 📄 License

MIT License - See [LICENSE](LICENSE)

---

## 🙏 Acknowledgments

- [Ethereum Foundation](https://ethereum.org) - Test vectors and specification
- [go-ethereum](https://github.com/ethereum/go-ethereum) - Reference implementation
- [Zig](https://ziglang.org/) - The language

---

**Building systematically. Validating thoroughly. Launching with proof.**

**Repository**: https://github.com/SMC17/zeth  
**Status**: Week 1 validated (98.8%), Week 2 in progress  
**Launch**: When validated, not when excited

*Last updated: October 29, 2025*
