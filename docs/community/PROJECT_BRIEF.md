# Zeth Project Brief

## What Zeth Is

Zeth is a Zig implementation of Ethereum Virtual Machine execution, built for correctness-first semantics today and high-leverage research/infra applications next.

## Current State (Source of Truth)

Use these files first:

- `STATUS_SUMMARY.md`
- `docs/architecture/EVM_PARITY_STATUS.md`
- CI artifacts: `opcode_report.json`, `precompile_differential_report.json`

## What Is Done

- Pinned Zig toolchain (`0.14.1`) with green core CI gates
- Implemented call/create + return-data plumbing baseline
- Implemented precompile routing `0x01..0x09` and differential reporting artifacts
- Added docs freshness CI gate to prevent stale status drift

## What Is Next (Execution Order)

1. Close remaining gas correctness edges with strict exact-gas tests.
2. Land transaction-scoped journaling/snapshots for nested commit/revert.
3. Close high-impact opcode parity gaps and expand differential corpus.
4. Scale validation hardening (per-op + per-precompile machine-readable CI tracking).
5. Build strategic tracks: `zeth-sim`, `zeth-wasm`, then `zeth-prove`.

## Why This Project Matters

Zeth targets differentiated upside where Zig can compound advantage:

- ZK-proving efficiency potential via lean execution and RISC-V path
- Embeddable EVM targets (WASM/edge/TEE)
- Deterministic, high-throughput simulation for MEV/research workloads
- Auditable execution core suitable for formal methods and protocol research

## New Contributor Start Here

1. Read `README.md`, then `STATUS_SUMMARY.md`.
2. Read `docs/community/EXECUTION_BACKLOG.md` for active milestones/issues.
3. Pick one issue with a clear gate and reproducible acceptance test.
