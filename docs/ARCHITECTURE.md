# Zeth Architecture

**Last Updated**: February 19, 2026

## Scope

Zeth is currently an execution-focused EVM implementation in Zig with differential validation tooling and CI regression gates.

This document describes the current architecture, not historical milestones.

## System Modules

### 1. Core Types (`src/types/`)

- `U256` arithmetic and conversion primitives
- Ethereum `Address` and `Hash` representations
- Shared low-level value semantics across EVM/state/validation paths

### 2. Cryptography (`src/crypto/`)

- Keccak-256 path used by EVM operations
- secp256k1 paths used by ECRECOVER-related behavior
- Precompile-supporting primitives and validation vectors

### 3. EVM Execution (`src/evm/`)

- Opcode dispatch and stack/memory/storage execution
- `CALL`, `STATICCALL`, `DELEGATECALL`, `CREATE`, `CREATE2` execution paths
- Return-data plumbing for nested execution flow
- Precompile routing for addresses `0x01..0x09`
- Gas accounting for opcode families and memory expansion paths

### 4. State Model (`src/state/`)

- Account model (balance, nonce, storage, code)
- External code introspection backing (`EXTCODESIZE`, `EXTCODECOPY`, `EXTCODEHASH`)
- Nested-call correctness work toward transaction-scoped journaling

### 5. Validation Tooling (`validation/`)

- Reference comparison runner (`run_reference_tests`)
- Machine-readable report generator (`opcode_report`)
- Differential precompile/opcode corpus used in CI artifact publication

## Execution Flow

1. Bytecode is decoded and dispatched through opcode handlers in `src/evm/evm.zig`.
2. State reads/writes route through the in-memory state model.
3. `CALL*`/`CREATE*` operations spawn nested execution contexts.
4. Return data and gas accounting are merged back into caller context.
5. Differential and report tooling validates semantic/gas behavior against expected vectors and optional references.

## Validation and CI Gates

Current quality gates are enforced in CI:

- `zig build test`
- opcode/precompile regression checks from generated JSON reports
- differential checks when reference implementations are available
- formatting and multi-target build jobs

Machine-readable artifacts are published each run:

- `opcode_report.json`
- `precompile_differential_report.json`

## Current Architecture Priorities

1. Finish gas correctness closure for remaining edge accounting.
2. Land transaction-scoped snapshot/journal semantics across nested calls.
3. Expand parity closure and differential corpus breadth.
4. Keep documentation status tied to executable/CI-backed metrics.

## Non-Goals (Current Phase)

The following are strategic follow-ons, not current architecture claims:

- full networking stack
- consensus implementation
- full node synchronization
- production RPC stack
