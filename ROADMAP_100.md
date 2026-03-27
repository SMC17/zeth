# Zeth Moonshot Roadmap: 100 Tasks to World-Class

**Goal**: Make Zeth the most impressive Zig blockchain project ever built — a correctness-proven, performance-optimized, zkVM-native EVM that passes the full Ethereum test suite and compiles to every target that matters.

**Current state**: 263 tests, 18K LoC, 142 opcodes dispatched, precompiles 0x01-0x09, state journaling, WASM + RISC-V targets building.

---

## Tier 1: Protocol Completeness (Tasks 1-25)
*Ship a spec-complete EVM that passes the Ethereum Foundation test suite.*

### Missing Opcodes (Shanghai/Cancun)
1. Implement PUSH0 (EIP-3855, Shanghai) — zero-cost zero push
2. Implement MCOPY (EIP-5656, Cancun) — efficient memory-to-memory copy
3. Implement TLOAD/TSTORE (EIP-1153, Cancun) — transient storage within tx
4. Implement BLOBHASH (EIP-4844, Cancun) — blob versioned hash access
5. Implement BLOBBASEFEE (EIP-7516, Cancun) — blob base fee opcode

### Gas Correctness
6. Fix gas-before-execution ordering — deduct gas BEFORE side effects per Yellow Paper
7. Implement EIP-3860 initcode size limit (49152 bytes) for CREATE/CREATE2
8. Implement EIP-170 contract code size limit (24576 bytes)
9. Implement EIP-2681 nonce limit (2^64 - 1)
10. Fix EIP-3529 SELFDESTRUCT refund removal (post-London: refund = 0, not 4800)
11. Implement gas refund cap at 1/5 of gas used (EIP-3529)
12. Implement intrinsic gas calculation (21000 base + calldata costs + access list)

### Transaction Execution
13. Implement transaction type 0 (legacy) execution with nonce/balance checks
14. Implement transaction type 1 (EIP-2930) with access lists
15. Implement transaction type 2 (EIP-1559) with priority fee / max fee
16. Implement transaction type 3 (EIP-4844) with blob gas
17. Implement transaction receipt generation (status, gas used, logs, bloom)
18. Implement log bloom filter calculation (EIP-7, 2048-bit bloom)
19. Implement effective gas price calculation per EIP-1559
20. Implement coinbase payment (gas_used * effective_gas_price to block.coinbase)

### State Completeness
21. Implement EIP-161 empty account cleanup (spurious dragon)
22. Implement access list pre-warming (EIP-2930)
23. Implement proper account creation rules (nonce=1 for created contracts)
24. Implement EIP-6780 SELFDESTRUCT-only-in-same-tx (Cancun behavior)
25. Implement warm coinbase address (EIP-3651, Shanghai)

---

## Tier 2: Ethereum Test Suite (Tasks 26-40)
*Pass every test in ethereum/tests and ethereum/execution-spec-tests.*

26. Run full VMTests suite and track pass rate (target: 100%)
27. Run GeneralStateTests for Berlin fork — track and fix failures
28. Run GeneralStateTests for London fork
29. Run GeneralStateTests for Shanghai fork
30. Run GeneralStateTests for Cancun fork
31. Implement JSON test fixture parser for GeneralStateTests format (pre/post state, tx, expect)
32. Implement state root verification against test expectations
33. Implement log hash verification against test expectations
34. Run ethereum/execution-spec-tests (EEST) Python framework
35. Achieve 100% on VMTests
36. Achieve 95%+ on GeneralStateTests/Berlin
37. Achieve 95%+ on GeneralStateTests/Cancun
38. Publish test pass rates as CI artifact with trend tracking
39. Set up nightly test runs against latest ethereum/tests HEAD
40. Implement test result diffing against previous runs for regression detection

---

## Tier 3: Performance (Tasks 41-55)
*Benchmark against revm and evmone. Get within 2x.*

41. Implement opcode dispatch via computed goto / function pointer table (not switch)
42. Implement stack as fixed-size array [1024]U256 instead of ArrayList
43. Implement memory as page-allocated arena instead of ArrayList(u8)
44. Profile hot paths with Zig's built-in instrumentation
45. Implement comptime keccak256 lookup tables for precompile address detection
46. Implement arena allocator for per-call-frame allocations
47. Benchmark: simple transfer transaction (compare vs revm)
48. Benchmark: ERC-20 transfer (compare vs revm)
49. Benchmark: Uniswap V2 swap (compare vs revm)
50. Benchmark: SHA3 throughput (compare vs evmone)
51. Benchmark: MODEXP throughput for large inputs
52. Benchmark: BN254 pairing throughput
53. Implement SIMD-accelerated U256 arithmetic where available
54. Implement lazy memory expansion (allocate on first write, not on size check)
55. Publish benchmark suite as CI job with performance regression detection

---

## Tier 4: EVMC Integration (Tasks 56-65)
*Drop-in replacement for geth/reth/besu's EVM.*

56. Implement full EVMC host interface bridge (account access, storage, balance, code)
57. Implement EVMC host callbacks for block hash lookup
58. Implement EVMC host callbacks for CALL/CREATE delegation
59. Implement EVMC host callbacks for SELFDESTRUCT
60. Implement EVMC host callbacks for log emission
61. Implement EVMC capabilities query (EVM1, EWASM, precompiles)
62. Implement EVMC set_option for configuration
63. Test EVMC plugin with evmc-cli tool
64. Test EVMC plugin against evmc-vmtester
65. Package EVMC plugin as downloadable release artifact

---

## Tier 5: zkVM / Provable Execution (Tasks 66-80)
*The killer feature: a provable EVM in Zig that compiles to RISC-V for SP1/RISC Zero.*

66. Verify Zeth compiles and executes correctly as SP1 guest program
67. Verify Zeth compiles and executes correctly as RISC Zero guest program
68. Remove all non-deterministic code paths (no random, no time-dependent behavior)
69. Implement deterministic allocator for zkVM targets (bump allocator)
70. Profile proving time for simple transfer transaction on SP1
71. Profile proving time for ERC-20 transfer on SP1
72. Optimize U256 arithmetic for RISC-V cycle count minimization
73. Optimize keccak256 for RISC-V (use precompile syscall if available)
74. Optimize secp256k1 for RISC-V (use precompile syscall if available)
75. Implement witness generation for efficient proving (pre-computed state reads)
76. Implement state proof verification (Merkle Patricia Trie proofs)
77. Build end-to-end demo: prove an Ethereum block with Zeth on SP1
78. Benchmark Zeth proving time vs revm-based provers
79. Implement incremental state commitment for efficient re-proving
80. Document the "Type 1 zkEVM via Zeth" architecture

---

## Tier 6: Developer Experience (Tasks 81-90)
*Make Zeth a joy to use and contribute to.*

81. Implement JSON-RPC server (eth_call, eth_estimateGas, eth_getCode)
82. Implement EVM trace output (structlog format compatible with geth debug_traceTransaction)
83. Implement EVM step debugger (breakpoints, single-step, inspect stack/memory/storage)
84. Implement Solidity revert reason decoding (ABI decode Error(string))
85. Write comprehensive API documentation with examples
86. Write "Getting Started" tutorial: execute your first contract
87. Write "Architecture Guide" explaining the codebase structure
88. Create GitHub issue templates for bug reports and feature requests
89. Set up GitHub Discussions for community Q&A
90. Create a project website with benchmarks, test pass rates, and architecture docs

---

## Tier 7: Advanced Features (Tasks 91-100)
*Differentiation — things no other Zig EVM does.*

91. Implement EOF (EVM Object Format, EIP-7692) for Prague fork
92. Implement Verkle Tree state commitment (EIP-6800, future fork)
93. Implement parallel EVM execution (block-level transaction parallelism)
94. Implement EVM execution tracing with gas profiler (per-opcode gas attribution)
95. Implement symbolic execution mode for formal verification
96. Implement fuzzing harness with coverage-guided mutation (libfuzzer integration)
97. Implement WASM execution in browser with JS bindings (npm package)
98. Implement native Ethereum P2P (devp2p/RLPx) for block sync
99. Implement light client state proof verification
100. Ship Zeth as a full Ethereum execution client (zeth-node)

---

## Dependency Graph

```
Tier 1 (Protocol) ──> Tier 2 (Tests) ──> Tier 3 (Perf) ──> Tier 7 (Advanced)
     │                     │                    │
     └──> Tier 4 (EVMC) ──┘                    │
     │                                          │
     └──> Tier 5 (zkVM) ───────────────────────┘
     │
     └──> Tier 6 (DX) ─────────────────────────>
```

## What Makes This The Most Impressive Zig Blockchain Project

1. **Only EVM that compiles to native + WASM + RISC-V from one codebase**
2. **Only EVM with formal correctness testing + differential validation + zkVM proving**
3. **Zig's comptime generates crypto tables at build time, not runtime**
4. **No GC, no hidden allocations = deterministic execution = perfect for zkVM**
5. **C ABI = EVMC plugin = drop-in for any Ethereum client**
6. **Performance within 2x of revm/evmone with 10x less code**
