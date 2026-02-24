# EVM Parity Status

**Last Updated**: February 24, 2026

## Snapshot

- `zig build test` is green on pinned Zig `0.14.1`.
- Opcode enum currently defines `143` entries.
- Dispatch switch currently has `142` explicit opcode handlers.
- Precompile routing is implemented for addresses `0x01..0x09`.
- `opcode_report` local sample is `33/33` passing with `14/14` precompile cases (no references available).

## Completed Recently

- Real call/create execution semantics with return-data plumbing
- External code introspection path backed by state (`EXTCODESIZE`, `EXTCODECOPY`, `EXTCODEHASH`)
- Keccak path replacement and expanded vectors
- Gas correctness batches for `CALL*`, `CREATE*`, `SELFDESTRUCT`, memory expansion, and nested forwarding edges
- Differential reporting artifacts (opcode + precompile dimensions)
- Signed-op and bit-op edge regressions (`SDIV`, `SMOD`, `SLT`, `SGT`, `SAR`, `SIGNEXTEND`)
- BN254 precompile corpus expansion including pairing canonical true/false/invalid vectors
- Static-mode write prohibition enforcement for `SSTORE`, `LOG*`, `CREATE*`, `SELFDESTRUCT`, and value-carrying calls

## Remaining High-Impact Gaps

1. Final gas-rule closure across remaining refund/accounting nuances (`CALL*`, `CREATE*`, `SELFDESTRUCT`, memory expansion edge cases)
2. Transaction-scoped journal/snapshot model for full nested commit/revert protocol fidelity
3. Additional parity closure on remaining edge semantics and fork-specific behavior (`BALANCE`, `EXTCODE*`, `BLOCKHASH`, remaining precompile edge corpora)
4. Broader reference corpus coverage against PyEVM/Geth in CI (where binaries are available)
5. Consensus-test harness expansion (`GeneralStateTests` execution path and `BlockchainTests`) after execution-core fidelity is stronger

## Validation Gate

No parity claim is considered closed unless:

- local test suite passes,
- differential fixtures pass (when references are available), and
- CI publishes green artifacts with no regressions.
