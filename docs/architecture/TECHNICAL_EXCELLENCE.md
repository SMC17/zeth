# Technical Excellence

**Last Updated**: February 19, 2026

## Definition

Technical excellence in Zeth means every externally stated capability is backed by tests, differential fixtures, and CI-enforced regression gates.

## Engineering Standards

1. Correctness before throughput optimization.
2. No status claims without reproducible evidence.
3. Every bug fix adds or strengthens a regression test.
4. Differential mismatches are tracked as first-class failures.
5. Documentation is treated as code and gated in CI.

## Evidence Model

Primary evidence sources:

- `zig build test`
- `zig build opcode-report -- --format json`
- `./zig-out/bin/run_reference_tests`
- GitHub Actions artifacts and job outcomes

No milestone is considered complete until all relevant gates are green locally and in CI.

## Correctness Gate Stack

### P0 Execution Correctness

- opcode semantics tests for critical paths
- precompile routing and behavior coverage (`0x01..0x09`)
- `CALL*`/`CREATE*` semantics and return-data plumbing tests

### P0 Gas Correctness

- exact `gas_used` assertions on critical flows
- no relaxed tolerances for key families
- regression checks on per-op/per-precompile gas deltas

### P1 Protocol Fidelity

- nested call snapshot commit/revert integration tests
- lifecycle scenarios for create/destruct/state transitions
- expanded differential corpus against available references

## Required Development Workflow

1. Implement change.
2. Add or update focused tests.
3. Run local gates.
4. Generate or verify machine-readable reports.
5. Merge only when CI is green.

## Metrics Discipline

Metrics are operational, not narrative. Track:

- pass/fail counts from executable reports
- differential mismatch count
- gas delta regressions
- canonical docs freshness checks

Avoid static claims that drift (old version tags, stale week labels, historical test counts) unless explicitly archived.

## Quality Risks to Monitor

1. Gas edge semantics drifting from fork rules.
2. Nested state side effects without full journaling.
3. Differential corpus too narrow to catch behavior regressions.
4. Documentation diverging from measured reality.

## Near-Term Excellence Targets

1. Close remaining gas-rule edge cases with strict goldens.
2. Complete transaction-scoped journal/snapshot model.
3. Increase differential corpus breadth and enforce regression failure.
4. Keep documentation and CI artifacts synchronized by default.
