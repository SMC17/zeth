# zeth-prove: RISC-V and zkVM Path

Zeth compiles to RISC-V for zkVM integration (SP1, RISC Zero). Zig-native zkEVM with smaller trace and cheaper proofs.

## Build

```bash
zig build riscv
```

Produces `zig-out/bin/zeth-riscv64` (ELF 64-bit RISC-V Linux executable).

## Running on RISC-V

### With QEMU (user-mode)

```bash
# Install qemu-user (Ubuntu: sudo apt install qemu-user)
qemu-riscv64 zig-out/bin/zeth-riscv64
```

### With QEMU (system emulation)

 Boot a RISC-V Linux image and run the binary natively.

## zkVM Integration

- **SP1**: Run `zeth-riscv64` (or a minimal EVM runner) inside the SP1 zkVM guest. Produce proofs of execution.
- **RISC Zero**: Similarly, compile Zeth to RISC-V and execute inside the RISC Zero zkVM.

The EVM core (evm, sim, state modules) has no platform-specific syscalls beyond the allocator; it is suitable for zkVM guest execution.

## Next Steps

1. Extract a minimal "execute(code, calldata) -> result" binary for zkVM
2. Integrate with SP1 or RISC Zero guest entry point
3. Benchmark proof cost (time, $) vs REVM-in-SP1 baseline
