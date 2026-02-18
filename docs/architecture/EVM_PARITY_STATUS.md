# EVM Parity Status

**Last Updated**: February 17, 2026  
**Source of Truth**: local measured build/test + source inspection

## Snapshot

- `zig build test`: passing on Zig `0.14.1`
- Tests: 106/106 passing
- Opcode enum entries in `src/evm/evm.zig`: 143
- Opcode dispatch handlers in `src/evm/evm.zig`: 141

## Recently Completed

- Toolchain and CI pinned to Zig `0.14.1`
- Zig stdlib API compatibility fixes across EVM/validation modules
- `EXP`, `SHL`, `SHR`, `SAR` implemented with concrete behavior
- Added/updated tests covering these opcode behaviors

## Still Incomplete or Partial

### System / Call Path

- `CALL` execution path is still simplified (does not execute target contract code)
- `STATICCALL` and `DELEGATECALL` remain simplified
- `CREATE`/`CREATE2` remain simplified address-return stubs

### External Account / Introspection Path

- `EXTCODESIZE` does not read real external code size
- `EXTCODECOPY` does not copy real external code
- `EXTCODEHASH` does not compute real account code hash

### Chain Data Dependency

- `BLOCKHASH` currently returns placeholder unless out-of-range handling applies

### Validation Infrastructure

- Geth reference execution path not implemented
- PyEVM result parsing does not yet parse stack contents for deep comparison

## Next Milestones

1. Complete real execution semantics for call/create family.
2. Complete external account code introspection semantics.
3. Expand reference-comparison coverage and discrepancy tracking.
4. Remove placeholder crypto/math implementations that affect Ethereum fidelity.

## Note on Older Documents

Some historical docs in this repository still contain January 2025 estimates (for example, "~70 opcodes"). Treat those as archival notes, not current parity metrics.
