# zkVM Integration Roadmap

Zeth targets RISC-V for ZK-provable EVM execution. Integration with SP1 and RISC Zero enables Zig-native zkEVM with smaller traces and cheaper proofs.

## Current State

| Component | Status |
|-----------|--------|
| RISC-V build | `zig build riscv` → `zig-out/bin/zeth-riscv64` |
| EVM core | No platform syscalls; zkVM-suitable |
| SP1 guest | Not started |
| RISC Zero guest | Not started |
| Proof benchmarking | Not started |

## Integration Path

### 1. Minimal zkVM Guest Binary

- Extract a minimal entry: `fn main() { execute(code, calldata) -> result }`
- Encode input/output via stdin/stdout or a small FFI
- Ensure no dynamic allocations in hot path where possible (or use fixed buffer)

### 2. SP1 Integration

- Add SP1 guest crate / build that invokes Zeth EVM
- SP1's `sp1-sdk` provides RISC-V guest API
- Produce proof of execution; verify on host

### 3. RISC Zero Integration

- Add RISC Zero guest program that links Zeth
- RISC Zero compiles guest to RISC-V; Zeth fits this model
- Produce receipts; verify externally

### 4. Benchmarking

- Compare proof time and cost: Zeth-in-SP1 vs REVM-in-SP1
- Target: smaller trace, fewer cycles, lower cost

## References

- [SP1](https://github.com/succinctlabs/sp1)
- [RISC Zero](https://github.com/risc0/risc0)
- [docs/riscv/README.md](README.md) — RISC-V build and QEMU
