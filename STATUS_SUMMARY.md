# Zeth Status Summary

**Snapshot Date**: March 26, 2026
**Revision**: `381f677` + pending
**Toolchain**: Zig `0.14.1`

## Measured State

Measured locally from this revision:

- `zig build test`: passes (263 tests, 0 failures)
- Opcode enum entries (`src/evm/evm.zig`): `143`
- Opcode dispatch handlers: `142`
- `TODO`/`FIXME` markers across `src/` + `validation/`: `2`
- `./zig-out/bin/run_reference_tests`: `22/22` pass in no-reference mode when PyEVM/Geth are unavailable
- `opcode_report` summary: total `33`, passed `33`, precompile tests `14`, precompile passed `14`, failures `0`
- Total Zig source: `18,608` lines across `35` files

## Correctness Fixes (This Revision)

- **U256 endianness**: Fixed `fromBytes`/`toBytes` to correctly map big-endian bytes to little-endian limb layout (limbs[0]=LSB, limbs[3]=MSB). Previously MSB was stored in limbs[0], causing incorrect memory layout for MSTORE/MLOAD relative to the EVM specification.
- **SIGNEXTEND**: Fixed byte-position guard to correctly handle positions >= 31 and large U256 positions (was masking with `& 31`, wrapping around). Fixed sign-bit-0 case to clear upper bytes (was leaving them unchanged).
- **SHL/SHR/SAR**: Fixed to return correct result when shift amount has non-zero upper limbs (shift >= 2^64).
- **EXP gas**: Fixed gas calculation to return 10 (not 60) when exponent is zero (byte-length is 0, not 1).

## Source-of-Truth Commands

```bash
zig version
zig build test
zig build opcode-report -- --format json --output /tmp/opcode_report.json
./zig-out/bin/run_reference_tests
```

## Active P0/P1 Workstreams

1. ~~Complete remaining gas-rule edge correctness~~ → Closed (stipend/refund edges, memory expansion goldens)
2. ~~Land transaction-scoped state journaling~~ → Closed (journal integration tests through EVM)
3. ~~Close high-impact parity gaps~~ → Closed (signed arithmetic, SIGNEXTEND, shift, environmental opcodes)
4. Differential validation hardening and CI regression gates (broader corpus, machine-readable reports)
5. Strategic tracks (`zeth-sim`, `zeth-wasm`, then `zeth-prove`)

## Notes

- Differential comparisons against PyEVM/Geth are CI-gated when references are available.
- Historical docs in `docs/internal/` and older roadmap/status files are archival context only.
- Local research drafts and future-facing notes not yet accepted as canonical are stored under `.local_docs_archive/` (gitignored).
