# EVM Parity Status

**Last Updated**: February 19, 2026

## Snapshot

- `zig build test` is green on pinned Zig `0.14.1`.
- Opcode enum currently defines `143` entries.
- Dispatch switch currently has `142` explicit opcode handlers.
- Precompile routing is implemented for addresses `0x01..0x09`.

## Completed Recently

- Real call/create execution semantics with return-data plumbing
- External code introspection path backed by state (`EXTCODESIZE`, `EXTCODECOPY`, `EXTCODEHASH`)
- Keccak path replacement and expanded vectors
- Gas correctness batches for `CALL*`, `CREATE*`, `SELFDESTRUCT`, memory expansion, and nested forwarding edges
- Differential reporting artifacts (opcode + precompile dimensions)

## Remaining High-Impact Gaps

1. Final gas-rule closure across edge/refund nuances where still unproven by differential fixtures
2. Transaction-scoped journal/snapshot model for full nested commit/revert protocol fidelity
3. Additional parity closure on remaining edge semantics and fork-specific behavior
4. Broader reference corpus coverage against PyEVM/Geth in CI

## Validation Gate

No parity claim is considered closed unless:

- local test suite passes,
- differential fixtures pass (when references are available), and
- CI publishes green artifacts with no regressions.
