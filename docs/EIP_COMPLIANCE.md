# Zeth EIP Compliance Matrix

Last updated: March 26, 2026 | Revision: f833c0b

This document tracks the implementation status of every EIP relevant to EVM execution correctness in Zeth. Status is determined by reading the source code directly, not by aspirational claims.

## Legend

- **DONE**: Fully implemented with tests
- **PARTIAL**: Core logic implemented but missing edge cases or untested paths
- **STUB**: Data structures or placeholders exist but behavior is incomplete
- **MISSING**: Not yet implemented
- **N/A**: Not applicable to an execution-only client

## Core Opcodes (Frontier)

| EIP | Name | Status | Notes |
|-----|------|--------|-------|
| - | Arithmetic (ADD, MUL, SUB, DIV, SDIV, MOD, SMOD, ADDMOD, MULMOD, EXP, SIGNEXTEND) | DONE | All 11 arithmetic opcodes dispatched in `executeOpcode` with gas charging |
| - | Comparison (LT, GT, SLT, SGT, EQ, ISZERO) | DONE | 6 comparison opcodes |
| - | Bitwise (AND, OR, XOR, NOT, BYTE) | DONE | 5 bitwise opcodes |
| - | SHA3 (Keccak-256) | DONE | Memory expansion gas + per-word gas |
| - | Environmental (ADDRESS, BALANCE, ORIGIN, CALLER, CALLVALUE, CALLDATALOAD, CALLDATASIZE, CALLDATACOPY, CODESIZE, CODECOPY, GASPRICE) | DONE | All 11 environmental opcodes |
| - | Block info (BLOCKHASH, COINBASE, TIMESTAMP, NUMBER, DIFFICULTY, GASLIMIT) | DONE | BLOCKHASH uses in-memory block_hashes map |
| - | Stack (POP, PUSH1-PUSH32, DUP1-DUP16, SWAP1-SWAP16) | DONE | 1 + 32 + 16 + 16 = 65 opcodes |
| - | Memory (MLOAD, MSTORE, MSTORE8, MSIZE) | DONE | Memory expansion gas accounting included |
| - | Storage (SLOAD, SSTORE) | DONE | Full EIP-2200/2929 gas model (see below) |
| - | Flow (JUMP, JUMPI, JUMPDEST, PC, GAS, STOP) | DONE | JUMPDEST validation present |
| - | Logging (LOG0-LOG4) | DONE | Static-call restriction enforced |
| - | System (CALL, CALLCODE, RETURN, CREATE, SELFDESTRUCT) | DONE | Nested execution with snapshot/revert |
| - | INVALID (0xFE) | DONE | Consumed gas, halts execution |
| - | Precompiles 0x01-0x09 | DONE | ecRecover, SHA-256, RIPEMD-160, identity, MODEXP, BN256ADD, BN256MUL, BN256PAIRING, BLAKE2F |

**Opcode count**: 148 opcodes dispatched (including all PUSH/DUP/SWAP variants), plus 9 precompiles.

## Homestead (Block 1,150,000)

| EIP | Name | Status | Notes |
|-----|------|--------|-------|
| EIP-2 | Homestead gas changes | DONE | CREATE base gas = 32000 in both `opCreate` and `opCreate2` |
| EIP-7 | DELEGATECALL | DONE | `opDelegateCall` implemented; preserves caller/value context |

## Tangerine Whistle (EIP-150, Block 2,463,000)

| EIP | Name | Status | Notes |
|-----|------|--------|-------|
| EIP-150 | 63/64 gas forwarding for calls | DONE | `eip150CallGasPlan()` computes `cap = available - available/64`; applied to CALL, STATICCALL, DELEGATECALL, CALLCODE, CREATE, CREATE2 |

## Spurious Dragon (EIP-158/161, Block 2,675,000)

| EIP | Name | Status | Notes |
|-----|------|--------|-------|
| EIP-158/161 | Empty account cleanup | PARTIAL | `destroyAccount` exists in StateDB but post-transaction empty account pruning is not systematically applied after every transaction |
| EIP-170 | Contract code size limit (24576 bytes) | DONE | `MAX_CODE_SIZE = 24576` enforced in both `opCreate` and `opCreate2` after init code execution |

## Byzantium (Block 4,370,000)

| EIP | Name | Status | Notes |
|-----|------|--------|-------|
| EIP-140 | REVERT opcode (0xFD) | DONE | Sets return data, triggers state revert via snapshot, returns remaining gas |
| EIP-211 | RETURNDATASIZE / RETURNDATACOPY | DONE | `return_data` tracked across call frames; boundary checks with memory expansion gas; recent fix for zero-length copy edge cases (commit b8da935) |
| EIP-214 | STATICCALL | DONE | `opStaticCall` sets `is_static = true` on child; LOG, SSTORE, CREATE, CREATE2, SELFDESTRUCT blocked in static context |
| EIP-658 | Status code in receipts | DONE | `Receipt.status: bool` in `receipt.zig`; RLP encodes 0x01/0x80 per spec |

## Constantinople (Block 7,280,000)

| EIP | Name | Status | Notes |
|-----|------|--------|-------|
| EIP-145 | Bitwise shift opcodes (SHL, SHR, SAR) | DONE | `u256Shl`, `u256Shr`, `u256Sar` with full 256-bit semantics including sign extension for SAR |
| EIP-1014 | CREATE2 | DONE | `opCreate2` with `keccak256(0xff ++ sender ++ salt ++ keccak256(init_code))` address derivation |
| EIP-1052 | EXTCODEHASH | DONE | `opExtCodeHash` reads code from StateDB, hashes with Keccak-256; returns 0 for non-existent accounts |
| EIP-1283 | Net gas metering for SSTORE | DONE | Superseded by EIP-2200; see Istanbul section |

## Istanbul (Block 9,069,000)

| EIP | Name | Status | Notes |
|-----|------|--------|-------|
| EIP-1344 | CHAINID opcode | DONE | `opChainId` reads from `context.chain_id` |
| EIP-1884 | Repriced opcodes (SLOAD, BALANCE, EXTCODEHASH) | DONE | Gas costs updated to Istanbul values via EIP-2929 warm/cold model |
| EIP-2028 | Transaction data gas reduction (16 gas/nonzero byte) | DONE | `TX_DATA_NONZERO_GAS = 16` in `transaction.zig` |
| EIP-2200 | SSTORE gas rework (net metering) | DONE | Full `opSstore` with original/current/new value logic: 20000 (fresh set), 2900 (dirty update), 100 (no-op); refund tracking for zero-setting and restoration |

## Berlin (Block 12,244,000)

| EIP | Name | Status | Notes |
|-----|------|--------|-------|
| EIP-2565 | MODEXP gas cost formula | DONE | `modexpRequiredGas()` implements the Berlin repricing formula; precompile 0x05 uses it |
| EIP-2718 | Typed transaction envelope | DONE | `TransactionType` enum: legacy (0), access_list (1), dynamic_fee (2) in `transaction.zig` |
| EIP-2929 | Warm/cold account access gas | DONE | `accountAccessCost()` returns 100 (warm) or 2600 (cold); `warm_accounts` HashMap tracks access; precompile addresses always warm |
| EIP-2930 | Access lists | DONE | `AccessListEntry` struct; `warmAccessList()` pre-warms accounts and storage keys; intrinsic gas charges (2400/address + 1900/key) |

## London (Block 12,965,000)

| EIP | Name | Status | Notes |
|-----|------|--------|-------|
| EIP-1559 | Base fee / dynamic fee transactions | DONE | `effectiveGasPrice()` computes `min(max_fee, base_fee + max_priority)`; coinbase receives priority fee only; base fee burned implicitly |
| EIP-3198 | BASEFEE opcode (0x48) | DONE | `opBaseFee` reads from `context.block_base_fee` |
| EIP-3529 | Refund cap reduced to gas_used/5; SELFDESTRUCT refund removed | PARTIAL | Refund cap at `evm_gas_used / 5` is correct in `transaction.zig`. However, SELFDESTRUCT still awards a 4800 gas refund (`opSelfDestruct` line 2999), which contradicts EIP-3529's removal of the SELFDESTRUCT refund. The SSTORE refund value of 4800 is correct per EIP-3529. |
| EIP-3541 | Reject contracts starting with 0xEF | MISSING | No check in `opCreate` or `opCreate2` for the 0xEF prefix on deployed bytecode. Code starting with 0xEF can be deployed. |

## Shanghai (April 2023)

| EIP | Name | Status | Notes |
|-----|------|--------|-------|
| EIP-3651 | Warm COINBASE | PARTIAL | `warmAccessList()` in `transaction.zig` pre-warms sender and recipient but does NOT pre-warm `block.coinbase`. The COINBASE address is charged cold (2600) on first touch. |
| EIP-3855 | PUSH0 opcode (0x5F) | DONE | `opPush0` pushes zero; gas cost = 2 (base) |
| EIP-3860 | Initcode size limit (49152 bytes) | DONE | `MAX_INITCODE_SIZE = 2 * MAX_CODE_SIZE` enforced in both `opCreate` and `opCreate2`; per-word gas `INITCODE_WORD_GAS = 2` charged |
| EIP-4895 | Beacon chain withdrawals | MISSING | No withdrawal processing in block execution (`block.zig` only processes transactions) |

## Cancun (March 2024)

| EIP | Name | Status | Notes |
|-----|------|--------|-------|
| EIP-1153 | Transient storage (TLOAD/TSTORE) | DONE | `TransientKey` scoped by address + slot; `transient_storage` HashMap; copied to child call frames; survives REVERT; cleared between transactions; gas = 100 each |
| EIP-4844 | Blob transactions / BLOBHASH / BLOBBASEFEE | PARTIAL | `BLOBHASH` opcode (0x49) reads from `context.blob_versioned_hashes`. `BLOBBASEFEE` opcode (0x4A) reads from `context.block_blob_base_fee`. However, Type 3 (blob) transaction handling, blob gas accounting, and the point evaluation precompile (0x0A) are NOT implemented. Only the opcodes are wired. |
| EIP-5656 | MCOPY opcode (0x5E) | DONE | `opMcopy` with overlap-safe copy (forward/backward direction); gas = 3 + 3*words + memory expansion |
| EIP-6780 | SELFDESTRUCT restriction | PARTIAL | `created_in_tx` HashMap tracks accounts created in the current transaction. CREATE and CREATE2 populate it. However, `opSelfDestruct` does NOT check `created_in_tx` -- it unconditionally destroys the account. The tracking infrastructure exists but the guard is not enforced. |
| EIP-7516 | BLOBBASEFEE opcode | PARTIAL | Opcode 0x4A defined and dispatched (same as EIP-4844 note above), but no blob gas pricing math exists. |

## Post-Cancun / Prague (Planned)

| EIP | Name | Status | Notes |
|-----|------|--------|-------|
| EIP-7702 | Set code for EOAs | MISSING | Not implemented |
| EIP-2537 | BLS12-381 precompiles | MISSING | Not implemented |
| EIP-7685 | General purpose execution layer requests | MISSING | Not implemented |

## Cross-Cutting Concerns

| Feature | Status | Notes |
|---------|--------|-------|
| Memory expansion gas model | DONE | `memoryExpansionCost()`: `new_words^2/512 + 3*new_words` delta formula |
| Stack depth limit (1024) | DONE | `Stack.max_depth = 1024`; overflow returns error |
| Call depth limit (1024) | PARTIAL | No explicit call depth counter; bounded by gas exhaustion via 63/64 forwarding |
| Journal/snapshot state revert | DONE | `StateDB.snapshot()` / `revertToSnapshot()` with `JournalEntry` for accounts, storage, and code changes |
| Transaction execution pipeline | DONE | Full flow: nonce check, intrinsic gas, balance check, EVM execution, refund cap, coinbase payment (`transaction.zig`) |
| Block execution pipeline | DONE | Sequential transaction execution, cumulative gas, receipt generation, state root computation (`block.zig`) |
| Receipt RLP encoding | DONE | EIP-2718 typed receipts, EIP-658 status, EIP-7 bloom filter (`receipt.zig`) |
| State trie / storage trie | DONE | `computeStateRoot()` and `computeStorageRoot()` in `state.zig` |
| RLP encoding/decoding | DONE | Full RLP implementation in `src/rlp/rlp.zig` with encoding, decoding, and invalid-input rejection |
| EIP-2681 nonce limit | DONE | `opCreate` checks `creator_nonce >= maxInt(u64)` |

## EIP Implementation Gap Summary

The following EIPs have known gaps that affect consensus correctness:

1. **EIP-3529 (SELFDESTRUCT refund)**: `opSelfDestruct` still awards 4800 gas refund. Post-London, SELFDESTRUCT should NOT generate a refund.
2. **EIP-3541 (0xEF prefix rejection)**: Deployed code starting with 0xEF is not rejected by CREATE/CREATE2.
3. **EIP-3651 (Warm COINBASE)**: The block coinbase address is not pre-warmed in the access list.
4. **EIP-6780 (SELFDESTRUCT restriction)**: The `created_in_tx` tracking exists but the conditional guard in `opSelfDestruct` is missing. All SELFDESTRUCT calls unconditionally destroy the account.
5. **EIP-4844 (Blob transactions)**: Only the BLOBHASH and BLOBBASEFEE opcodes are implemented. Type 3 transactions, blob gas accounting, and the point evaluation precompile (0x0A) are not present.
6. **EIP-158/161 (Empty account cleanup)**: Post-transaction pruning of empty accounts is not systematically applied.

## Validation Coverage

Status claims above are cross-referenced against:

- **Unit tests**: `src/evm/evm.zig` (inline tests), `comprehensive_test.zig`, `edge_case_tests.zig`, `parity_edge_tests.zig`, `journal_integration_test.zig`
- **Consensus tests**: `validation/vm_test_runner.zig` (Ethereum VMTests), `validation/state_test_runner.zig` (GeneralStateTests)
- **Differential testing**: `validation/differential_fuzz.zig` (Zeth vs PyEVM), `validation/comparison_tool.zig`
- **Regression gates**: `validation/regression_gate.zig`, `validation/vector_runner.zig`
- **Manual verification**: `validation/manual_opcode_tests.zig`, `validation/opcode_verification.zig`
