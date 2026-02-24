# Zeth Status Summary

**Snapshot Date**: February 24, 2026  
**Revision**: `084c26e`  
**Toolchain**: Zig `0.14.1`

## Measured State

Measured locally from this revision:

- `zig build test`: passes
- Opcode enum entries (`src/evm/evm.zig`): `143`
- Opcode dispatch handlers (`src/evm/evm.zig` switch arms): `142`
- `TODO`/`FIXME` markers across `src/` + `validation/`: `2`
- `./zig-out/bin/run_reference_tests`: `22/22` pass in no-reference mode when PyEVM/Geth are unavailable
- `opcode_report` summary sample (local, no references): total `33`, passed `33`, precompile tests `14`, precompile passed `14`, failures `0`
- Latest verified CI batch (static-mode write prohibitions): GitHub Actions run `22356024341` green

## Source-of-Truth Commands

```bash
zig version
zig build test
zig build opcode-report -- --format json --output /tmp/opcode_report.json
./zig-out/bin/run_reference_tests
```

## Active P0/P1 Workstreams

1. Complete remaining gas-rule edge correctness and exact gas goldens (refund/accounting edges)
2. Land transaction-scoped state journaling (snapshot/commit/revert across nested calls)
3. Close high-impact parity gaps and expand differential corpus / reference coverage

## Notes

- Differential comparisons against PyEVM/Geth are CI-gated when references are available.
- Historical docs in `docs/internal/` and older roadmap/status files are archival context only.
- Local research drafts and future-facing notes not yet accepted as canonical are stored under `.local_docs_archive/` (gitignored).
