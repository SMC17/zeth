# Execution Backlog (Canonical)

## Purpose

This file maps strategic direction to concrete GitHub issues so contributors can execute without ambiguity.

## Working Model

- `Path A`: correctness and protocol fidelity foundation (must complete first)
- `Path B`: strategic unlock tracks after `Path A` is stable

## Milestone A0: Gas Correctness Closure

Goal: complete CALL*/CREATE*/SELFDESTRUCT/memory-expansion edge correctness with exact gas assertions.

Gate:

- `zig build test` green
- gas golden tests exact (`==`) for critical flows
- CI green without relaxed tolerances

GitHub Tracking:

- Epic: `#2`
- Batches: `#3`, `#4`

## Milestone A1: State Journaling / Snapshots

Goal: transaction-scoped nested snapshot/commit/revert semantics across state transitions.

Gate:

- nested integration tests for revert/commit behavior
- storage/balance/nonce/code/selfdestruct lifecycle covered

GitHub Tracking:

- Epic: `#5`
- Batches: `#6`, `#7`

## Milestone A2: Opcode Parity + Validation Hardening

Goal: close high-impact missing semantics and widen differential coverage.

Gate:

- per-op and per-precompile artifact published each run
- regression fails CI on mismatches/delta drift

GitHub Tracking:

- Epic: `#8`
- Batches: `#9`, `#10`

## Milestone B0: Strategic Unlock Track

Goal: start modular expansion once correctness base is stable.

Sequence:

1. `zeth-sim` deterministic simulation API
2. `zeth-wasm` browser/edge target
3. `zeth-prove` prep (`zeth-riscv` + zkVM integration)

GitHub Tracking:

- Epic: `#11`
- Batches: `#12`, `#13`, `#14`, `#15`

## Tracking Rules

- Every issue must include: scope, explicit non-goals, acceptance gate, and verification command.
- Every merged PR must link issue + show gate evidence.
- If status changes, update issue and `STATUS_SUMMARY.md` instead of adding conflicting docs.

## Execution Start Order

1. `#3` then `#4`
2. `#6` then `#7`
3. `#9` then `#10`
4. After Path A is stable, start `#12` -> `#13` -> `#14` -> `#15`
