# Zeth - Ethereum Virtual Machine in Zig

[![CI Status](https://github.com/SMC17/zeth/workflows/CI/badge.svg)](https://github.com/SMC17/zeth/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Zig](https://img.shields.io/badge/Zig-0.14.1-orange.svg)](https://ziglang.org/)

Zeth is a Zig EVM focused on correctness-first execution semantics, differential validation, and a path to high-performance research tooling.

## Current Reality

As of **February 19, 2026**:

- Toolchain is pinned to `Zig 0.14.1`.
- `zig build test` passes locally.
- EVM includes call/create execution paths, precompile routing (`0x01..0x09`), and expanded gas tests.
- CI publishes machine-readable validation artifacts for opcode and precompile differential reporting.

For measured details, use:

- `STATUS_SUMMARY.md`
- `zig build opcode-report -- --format json`
- GitHub Actions artifacts (`opcode_report.json`, `precompile_differential_report.json`)

## Quick Start

### Prerequisites

- Zig `0.14.1`
- Python 3.11+ (optional, for PyEVM-based validation)

### Build and Test

```bash
git clone https://github.com/SMC17/zeth.git
cd zeth
zig build
zig build test
```

### Examples

```bash
zig build run-counter
zig build run-storage
zig build run-arithmetic
zig build run-events
```

### Validation

```bash
# RLP validators
zig build validate-rlp
zig build validate-rlp-decode
zig build validate-rlp-invalid

# Machine-readable opcode/precompile report
zig build opcode-report -- --format json --output /tmp/opcode_report.json

# Differential runner (uses PyEVM/Geth if available)
./zig-out/bin/run_reference_tests

# VMTests (requires: git clone https://github.com/ethereum/tests ethereum-tests)
zig build validate-vm
```

## Project Priorities

Current execution order:

1. Gas correctness closure (`CALL*`, `CREATE*`, `SELFDESTRUCT`, memory expansion/refund edge cases)
2. State journaling and nested snapshot commit/revert semantics
3. High-impact opcode parity closure (remaining edge semantics + precompiles)
4. Differential validation hardening and CI regression gates
5. Strategic tracks (`zeth-sim`, `zeth-wasm`, then `zeth-prove`)

## Documentation Map

- `STATUS_SUMMARY.md`: single measured status snapshot
- `docs/architecture/EVM_PARITY_STATUS.md`: parity and correctness deltas
- `docs/architecture/STRATEGIC_ROADMAP.md`: long-horizon strategy
- `docs/architecture/DOCUMENTATION_AUDIT_2026-02-19.md`: documentation audit and cleanup actions
- `docs/community/PROJECT_BRIEF.md`: one-page project orientation
- `docs/community/EXECUTION_BACKLOG.md`: canonical milestone/issue sequence
- `docs/internal/*`: historical planning/session material (not source of truth)

## Contributing

See `CONTRIBUTING.md` for contribution workflow and standards.

## Status

Alpha software under active development. Claims should be tied to passing tests, differential results, and CI artifacts.
