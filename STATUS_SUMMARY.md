# Zeth Status Summary

**Snapshot Date**: February 19, 2026  
**Revision**: `c42a54f`  
**Toolchain**: Zig `0.14.1`

## Measured State

Measured locally from this revision:

- `zig build test`: passes
- Opcode enum entries (`src/evm/evm.zig`): `143`
- Opcode dispatch handlers (`src/evm/evm.zig` switch arms): `142`
- `TODO`/`FIXME` markers across `src/` + `validation/`: `2`
- `./zig-out/bin/run_reference_tests`: `22/22` pass in no-reference mode when PyEVM/Geth are unavailable
- `opcode_report` summary sample: total `22`, precompile tests `11`, failures `0` (local run without references)

## Source-of-Truth Commands

```bash
zig version
zig build test
zig build opcode-report -- --format json --output /tmp/opcode_report.json
./zig-out/bin/run_reference_tests
```

## Active P0/P1 Workstreams

1. Complete gas-rule edge correctness and exact gas goldens
2. Land transaction-scoped state journaling (snapshot/commit/revert across nested calls)
3. Close high-impact parity gaps and expand differential corpus

## Notes

- Differential comparisons against PyEVM/Geth are CI-gated when references are available.
- Historical docs in `docs/internal/` and older roadmap/status files are archival context only.
