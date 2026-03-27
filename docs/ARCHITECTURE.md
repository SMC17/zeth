# Zeth Architecture

**Last Updated**: March 26, 2026 | Revision: f833c0b

## System Overview

Zeth is an Ethereum Virtual Machine implementation written in Zig, targeting execution correctness across multiple deployment surfaces: native (CLI/benchmarks), EVMC plugin (drop-in for Geth/Reth/Besu), WebAssembly (browser/edge), and RISC-V (zkVM proving via SP1/RISC Zero/Jolt). The same EVM core compiles to all targets with zero conditional compilation in the execution path. Zeth currently implements opcodes through the Cancun hard fork with differential validation against the Ethereum consensus test suite and PyEVM.

## Module Map

```
                        ┌──────────┐
                        │  types   │ U256, Address, Hash, Account, Transaction
                        └────┬─────┘
                             │
              ┌──────────────┼──────────────┐
              │              │              │
         ┌────▼───┐    ┌────▼───┐    ┌─────▼────┐
         │ crypto │    │  rlp   │    │  state   │ StateDB, journal, trie
         └────┬───┘    └────┬───┘    └─────┬────┘
              │             │              │
              └──────┬──────┘              │
                     │                     │
                ┌────▼─────────────────────▼────┐
                │             evm               │ Opcode dispatch, gas, precompiles
                └────┬──────────┬───────────────┘
                     │          │
          ┌──────────┼──────────┼──────────┐
          │          │          │          │
     ┌────▼───┐ ┌───▼────┐ ┌──▼───┐ ┌────▼──────┐
     │  sim   │ │ trans-  │ │ evmc │ │   zkvm    │
     │        │ │ action  │ │      │ │           │
     └────┬───┘ └───┬────┘ └──────┘ └───────────┘
          │         │
          │    ┌────▼────┐
          │    │ receipt  │
          │    └────┬────┘
          │         │
          │    ┌────▼────┐
          │    │  block   │
          │    └─────────┘
          │
     ┌────▼───┐
     │  rpc   │ JSON-RPC handler (eth_call, eth_estimateGas, ...)
     └────┬───┘
          │
     ┌────▼───┐
     │  wasm  │ Browser/edge FFI (wasm32-wasi)
     └────────┘
```

### Module Descriptions

| Module | Path | Purpose |
|--------|------|---------|
| **types** | `src/types/types.zig` | U256 arithmetic, Address, Hash, Account, legacy Transaction structs. Shared value semantics across all modules. |
| **crypto** | `src/crypto/crypto.zig` | Keccak-256, RIPEMD-160, secp256k1 ECRECOVER. Used by EVM opcodes and precompiles. |
| **rlp** | `src/rlp/rlp.zig` | Recursive Length Prefix encoding and decoding. Used by state trie, receipt encoding, and validation tooling. |
| **state** | `src/state/state.zig` | StateDB: account model (balance, nonce, code, storage), journal/snapshot/revert for nested calls, Merkle Patricia Trie for state and storage roots. |
| **evm** | `src/evm/evm.zig` | Core EVM: 148-opcode dispatch, stack (1024 depth), memory with expansion gas, 9 precompiles, EIP-150 gas forwarding, EIP-2929 warm/cold access, EIP-2200 SSTORE metering, EIP-1153 transient storage. Also contains `bn254_pairing.zig` for the BN256 pairing precompile. |
| **transaction** | `src/evm/transaction.zig` | Transaction types (legacy, EIP-2930, EIP-1559), intrinsic gas, effective gas price, full transaction execution pipeline with nonce/balance validation, access list warming, refund cap, coinbase payment. |
| **receipt** | `src/evm/receipt.zig` | EIP-658 receipts with status code, cumulative gas, EIP-7 bloom filter, EIP-2718 typed receipt RLP encoding. |
| **block** | `src/evm/block.zig` | Block header, sequential transaction execution, cumulative gas tracking, bloom filter aggregation, state root computation. |
| **sim** | `src/sim.zig` | Clean execution API over the EVM core. Wraps `ExecutionRequest` / `ExecutionResult` for library consumers. |
| **rpc** | `src/rpc/server.zig` | JSON-RPC handler (EIP-1474 subset): eth_call, eth_estimateGas, eth_chainId, eth_blockNumber, eth_getBalance, eth_getCode, eth_getStorageAt. Transport-agnostic (no HTTP server). |
| **evmc** | `src/evmc/zeth_evmc.zig` | EVMC v12 C ABI bridge. Builds as `libzeth_evmc.so/.dylib` for drop-in use by Geth, Silkworm, Besu, or any EVMC-compatible client via `dlopen`. |
| **zkvm** | `src/zkvm/zeth_guest.zig` | zkVM guest program. Reads transaction input from host I/O, executes via EVM, commits result. Compiles to both native (testing) and rv32im-freestanding (proving). Uses 512KB fixed-buffer allocator. |
| **wasm** | `src/wasm/zeth_evm.zig` | WebAssembly FFI entry point. Exports `zeth_execute(input_ptr, input_len, output_ptr, output_cap)` for browser/edge embedding. Uses 256KB fixed-buffer allocator. |

### Dependency Rules

1. **types** and **crypto** have no internal dependencies (leaf modules).
2. **rlp** has no internal dependencies.
3. **state** depends on types, crypto, rlp.
4. **evm** depends on types, crypto, state.
5. **transaction** depends on types, crypto, state, evm.
6. **receipt** depends on types, crypto, evm, transaction, rlp.
7. **block** depends on types, state, evm, transaction, receipt.
8. **sim** depends on evm, types, state.
9. **rpc** depends on sim, types, state.
10. **evmc** depends on types, evm, state.
11. **zkvm** depends on evm, types.
12. **wasm** depends on sim.
13. No circular dependencies exist. The graph is a DAG.

## Build Targets

Zeth produces multiple artifacts from the same source tree via `build.zig`:

| Target | Command | Output | Purpose |
|--------|---------|--------|---------|
| **Native CLI** | `zig build` | `zig-out/bin/zeth` | Main executable, demos, development |
| **Unit tests** | `zig build test` | (runs inline) | All module tests + comprehensive/edge/parity/journal/transaction/receipt/block/evmc/zkvm/rpc tests |
| **Benchmarks** | `zig build bench` | `zig-out/bin/benchmarks` | Performance benchmarks (ReleaseFast) |
| **EVMC plugin** | `zig build evmc` | `zig-out/lib/libzeth_evmc.{so,dylib}` | Drop-in EVM for Geth/Reth/Besu (ReleaseSmall) |
| **WASM** | `zig build wasm` | `zig-out/lib/zeth_evm.wasm` | Browser/edge EVM (wasm32-wasi, ReleaseSmall) |
| **RISC-V 64** | `zig build riscv` | `zig-out/bin/zeth-riscv64` | Cross-compiled for riscv64-linux-gnu |
| **RISC-V 32** | `zig build riscv32` | `zig-out/bin/zeth-rv32` | zkVM guest binary (riscv32-linux-musl, ReleaseSmall) for SP1/RISC Zero/Jolt |
| **VMTests** | `zig build validate-vm` | JSON summary | Ethereum consensus VMTests runner |
| **StateTests** | `zig build state-test` | JSON summary | Ethereum GeneralStateTests runner |
| **RLP validation** | `zig build validate-rlp` | (stdout) | Validate RLP encoding against ethereum-tests |
| **RLP decode** | `zig build validate-rlp-decode` | (stdout) | Validate RLP decoding against ethereum-tests |
| **RLP invalid** | `zig build validate-rlp-invalid` | (stdout) | Test invalid RLP rejection |
| **Vector run** | `zig build vector-run -- path/to/vectors.json` | (stdout) | Test vector regression pipeline |
| **Regression gate** | `zig build regression-gate -- baseline.json current.json` | (exit code) | CI gate: compare discrepancy JSON against baseline |
| **Opcode report** | `zig build opcode-report` | JSON | Machine-readable opcode/gas report |
| **Differential fuzz** | `zig build differential-fuzz` | JSON | Zeth vs PyEVM differential fuzzing |
| **Opcode docs** | `zig build opcode-docs -- docs/opcodes.md` | Markdown | Generated opcode reference |
| **Examples** | `zig build run-counter`, `run-storage`, `run-arithmetic`, `run-events` | (stdout) | Example programs |

## Data Flow

### Transaction Execution Path

```
 JSON-RPC request (eth_call / eth_sendRawTransaction)
        │
        ▼
   rpc/server.zig ── parses JSON-RPC, extracts params
        │
        ▼
   sim.zig ── builds ExecutionRequest, creates EVM context
        │
        ▼
   transaction.zig :: executeTransaction()
        │
        ├─ 1. Validate nonce (sender_nonce == tx.nonce)
        ├─ 2. Compute intrinsic gas (21000 base + calldata + access list)
        ├─ 3. Validate gas limit <= block gas limit
        ├─ 4. Compute effective gas price (EIP-1559)
        ├─ 5. Check balance >= value + gas_limit * gas_price
        ├─ 6. Deduct upfront gas payment from sender
        ├─ 7. Increment sender nonce
        ├─ 8. Snapshot state (for revert on failure)
        ├─ 9. Pre-warm access list (EIP-2930)
        │
        ▼
   evm.zig :: EVM.execute()
        │
        ├─ Opcode fetch-decode-execute loop
        │   ├─ Arithmetic/logic: pure stack operations
        │   ├─ Memory: expand + gas charge via memoryExpansionCost()
        │   ├─ Storage: SLOAD/SSTORE via StateDB with warm/cold gas (EIP-2929/2200)
        │   ├─ CALL/STATICCALL/DELEGATECALL/CALLCODE:
        │   │   ├─ eip150CallGasPlan() computes 63/64 forwarding
        │   │   ├─ Precompile check (addresses 0x01-0x09)
        │   │   ├─ Or: spawn child EVM via initChildWithState()
        │   │   ├─ Snapshot/revert on child failure
        │   │   └─ Merge warm sets + transient storage back to parent
        │   ├─ CREATE/CREATE2:
        │   │   ├─ Address derivation (RLP or keccak256(0xff++sender++salt++hash))
        │   │   ├─ EIP-3860 initcode size limit + per-word gas
        │   │   ├─ Child EVM execution of init code
        │   │   ├─ EIP-170 deployed code size limit
        │   │   └─ Store returned bytecode via StateDB.setCode()
        │   └─ RETURN/REVERT/STOP/SELFDESTRUCT: halt execution
        │
        ▼
   ExecutionResult { success, gas_used, gas_refund, return_data, logs }
        │
        ▼
   transaction.zig (continued)
        ├─ 10. Compute refund (capped at gas_used / 5, EIP-3529)
        ├─ 11. Commit or revert snapshot
        ├─ 12. Refund unused gas to sender
        └─ 13. Pay coinbase: net_gas_used * priority_fee
        │
        ▼
   block.zig :: executeBlock()
        ├─ Execute transactions sequentially
        ├─ Accumulate cumulative gas, aggregate bloom filter
        ├─ Generate receipts (EIP-658 status + EIP-2718 typed encoding)
        └─ Compute state root via Merkle Patricia Trie
        │
        ▼
   BlockResult { receipts, gas_used, logs_bloom, state_root }
```

### State Model

StateDB manages four hash maps:
- **accounts**: `Address -> Account` (balance, nonce, storage_root, code_hash)
- **storage**: `(Address, U256) -> U256` (contract storage slots)
- **code**: `Address -> []u8` (contract bytecode)
- **journal**: append-only log of `JournalEntry` (account changes, storage changes, code changes)

Snapshots are checkpoint indices into the journal. `revertToSnapshot()` replays journal entries in reverse to undo changes. This enables nested CALL/CREATE revert semantics without copying state.

## Test Architecture

Zeth uses a four-layer test pyramid:

### Layer 1: Unit Tests (fastest, most numerous)

Run via `zig build test`. Each module contains inline `test` blocks:
- `src/types/types.zig` — U256 arithmetic, edge cases (`edge_case_tests.zig`)
- `src/crypto/crypto.zig` — Keccak-256, RIPEMD-160, ECRECOVER vectors
- `src/rlp/rlp.zig` — Encoding/decoding round-trips
- `src/evm/evm.zig` — Per-opcode tests
- `src/evm/comprehensive_test.zig` — Multi-opcode scenarios
- `src/evm/edge_case_tests.zig` — Boundary conditions (overflow, underflow, zero-length)
- `src/evm/parity_edge_tests.zig` — Signed arithmetic, bitwise shifts, env opcodes
- `src/evm/journal_integration_test.zig` — Nested CALL/CREATE/SELFDESTRUCT state journaling
- `src/evm/transaction.zig` — Transaction execution (legacy, EIP-2930, EIP-1559)
- `src/evm/receipt.zig` — Bloom filter, typed receipt encoding
- `src/evm/block.zig` — Block execution, state root
- `src/evmc/zeth_evmc.zig` — EVMC bridge
- `src/zkvm/io.zig`, `zeth_guest.zig` — zkVM I/O and guest program
- `src/rpc/server.zig` — JSON-RPC handler

### Layer 2: Integration / Validation Tests

- `validation/manual_opcode_tests.zig` — Hand-crafted opcode verification
- `validation/opcode_verification.zig` — Opcode gas and result verification
- `validation/comparison_tool.zig` — Cross-implementation comparison framework

### Layer 3: Differential Testing

- `validation/differential_fuzz.zig` — Automated fuzzing: Zeth vs PyEVM (`pyevm_executor.py`)
- `validation/reference_test_runner.zig` — Reference implementation comparison
- `validation/reference_interfaces.zig` — Abstraction over multiple reference implementations
- `validation/discrepancy_tracker.zig` — Machine-readable discrepancy tracking
- `validation/opcode_report.zig` — Generated opcode/gas report for CI artifacts

### Layer 4: Consensus Tests (most authoritative)

- `validation/vm_test_runner.zig` — Runs official Ethereum VMTests from `ethereum/tests`
- `validation/state_test_runner.zig` — Runs official GeneralStateTests from `ethereum/tests`
- `validation/vector_runner.zig` — Converted test vector regression
- `validation/regression_gate.zig` — CI gate: fail if discrepancy count increases vs baseline

### CI Pipeline

The GitHub Actions CI (`ci.yml`) runs on every push/PR to `main`/`develop`:

1. `zig build test` — all unit tests
2. `zig build validate-rlp` / `validate-rlp-decode` / `validate-rlp-invalid` — RLP consensus
3. `zig build validate-vm` — Ethereum VMTests (when `ethereum-tests` is available)
4. Vector pipeline: convert VMTests to vectors, run regression
5. Differential fuzz: Zeth vs PyEVM
6. Machine-readable artifacts published: `opcode_report.json`, `precompile_differential_report.json`, `vmtest_summary.json`

## Key Design Decisions

### Why Zig

1. **No hidden allocations.** Every allocation is explicit via `std.mem.Allocator`, which is critical for (a) deterministic execution in zkVM guests with fixed-buffer allocators and (b) accurate gas accounting where memory expansion cost must be precisely tracked.

2. **Comptime.** The opcode dispatch table, stack depth limit, and precompile gas tables are all comptime-known, enabling the compiler to generate optimal switch dispatch. The same source compiles to native, WASM, and RISC-V without `#ifdef` or runtime feature detection.

3. **Cross-compilation.** `zig build riscv32` produces a rv32im-linux-musl binary from the same source tree that `zig build` uses for native. No separate toolchain, no Docker, no cross-compilation scripts. This is essential for the zkVM target.

4. **No runtime.** No GC, no async runtime, no hidden threads. The EVM execution path is a pure synchronous function call, which makes it safe to embed in EVMC hosts, WASM runtimes, and zkVM environments that have severe constraints on system calls.

5. **C ABI for free.** The EVMC plugin (`libzeth_evmc.so`) exports `evmc_create_zeth()` with `callconv(.C)` at zero cost. No FFI bridge generator needed.

### Why This Module Structure

- **types/crypto/rlp as leaf modules** ensures the EVM core has no circular dependencies and can be tested in isolation.
- **state separated from evm** allows StateDB to be swapped for different backends (in-memory for tests, trie-backed for production, host callbacks for EVMC).
- **transaction and receipt separate from evm** keeps the EVM as a pure bytecode executor. Transaction validation (nonce, balance, gas price) and receipt generation are higher-level concerns.
- **sim as a facade** provides a stable API for external consumers (WASM, RPC) without exposing EVM internals.

### State Architecture

The journal/snapshot model was chosen over copy-on-write for nested calls because:
- Copy-on-write would require cloning the entire storage map on each CALL, which is O(n) in storage size.
- Journal entries are O(1) append and O(k) revert where k is the number of changes in the reverted frame.
- This matches how production EVM implementations (Geth, Reth) handle nested call state.

### Gas Accounting

Gas is tracked as a running `gas_used` counter rather than a remaining-gas counter. This simplifies the 63/64 forwarding calculation and avoids underflow bugs. The `gas_limit - gas_used` computation happens only when needed (child call gas allocation, OOG checks).

## Documentation Governance

- Canonical architecture and compliance docs live in `docs/` and must stay current with the source code.
- Historical planning and session context lives under `docs/internal/` (archived reference, not source of truth).
- CI enforces docs freshness via `scripts/check_docs_fresh.sh`.
- EIP compliance status in `docs/EIP_COMPLIANCE.md` is derived from source-reading, not aspirational claims.

## Non-Goals (Current Phase)

The following are strategic follow-ons, not current architecture claims:

- Full networking / devp2p stack
- Consensus implementation (PoS beacon chain interaction)
- Full node synchronization
- Production HTTP/WebSocket JSON-RPC transport (the handler exists; the server does not)
- EIP-4844 blob transaction validation and data availability
- Prague hard fork EIPs (EIP-7702, EIP-2537)
