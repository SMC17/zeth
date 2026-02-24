# Execution Backlog (Canonical)

## Purpose

This file maps strategic direction to concrete GitHub issues so contributors can execute without ambiguity.

## Working Model

- `Path A`: correctness and protocol fidelity foundation (must complete first)
- `Path B`: strategic unlock tracks after `Path A` is stable

## Current Status (February 24, 2026)

- Initial Path A issue train is complete and green in CI: `#3`, `#4`, `#6`, `#7`, `#9`, `#10`.
- Recent follow-on parity/correctness batches (post-`#10`) landed:
  - signed-op and `SIGNEXTEND` fixes + parity vectors
  - `CALLCODE` storage-context regression
  - `EXTCODECOPY` memory gas correction + state edge tests
  - static-context write prohibition enforcement and regressions
- Current next focus remains Path A completion in substance: gas edge closure, journaling, broader parity/differential coverage.

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
- Status: base batch sequence complete; follow-on parity closure continues in subsequent commits/issues

## Milestone B0: Strategic Unlock Track

Goal: start modular expansion once correctness base is stable.

Sequence:

1. `zeth-sim` deterministic simulation API
2. `zeth-wasm` browser/edge target
3. `zeth-prove` prep (`zeth-riscv` + zkVM integration)

GitHub Tracking:

- Epic: `#11`
- Batches: `#12`, `#13`, `#14`, `#15`
- Status: blocked on stronger Path A correctness/protocol-fidelity base

## Tracking Rules

- Every issue must include: scope, explicit non-goals, acceptance gate, and verification command.
- Every merged PR must link issue + show gate evidence.
- If status changes, update issue and `STATUS_SUMMARY.md` instead of adding conflicting docs.

## Execution Order (Current)

1. Finish Path A correctness closure work not fully exhausted by the initial issue train:
   - gas-rule edge/refund accounting closure
   - state journaling/snapshots
   - parity edge semantics + broader differential coverage
2. Convert remaining slack items into explicit issues with gates (GeneralStateTests harness, BlockchainTests, pre-state loader support, differential expansion)
3. After Path A gates are consistently green, start `#12` -> `#13` -> `#14` -> `#15`
