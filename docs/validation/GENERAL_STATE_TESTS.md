# GeneralStateTests Harness

Ethereum **GeneralStateTests** exercise the full state transition function: pre-state, transaction, block context, and expected post-state.

## Format

```json
{
  "testName": {
    "env": {
      "currentCoinbase": "0x...",
      "currentDifficulty": "0x...",
      "currentGasLimit": "0x...",
      "currentNumber": "0x...",
      "currentTimestamp": "0x...",
      "currentBaseFee": "0x...",
      "currentRandom": "0x...",
      ...
    },
    "pre": { "address": { "balance", "nonce", "code", "storage" }, ... },
    "transaction": {
      "data": ["0x..."],
      "gasLimit": ["0x..."],
      "gasPrice": "0x...",
      "nonce": "0x...",
      "secretKey": "0x...",
      "to": "0x..." | "",
      "value": ["0x..."],
      ...
    },
    "post": {
      "Berlin": [{ "hash": "0x...", "logs": "0x...", "indexes": {...} }],
      "London": [...],
      ...
    }
  }
}
```

- **pre** — Initial world state (same structure as VMTests).
- **env** — Block context (coinbase, gas limit, base fee, etc.).
- **transaction** — Signed transaction; arrays denote variant dimensions.
- **post** — Expected results per fork (state root hash, logs hash, variant indexes).

## Current Status

| Component          | Status |
|-------------------|--------|
| VMTests           | Implemented (`zig build validate-vm`) |
| pre-state loading | Shared with VMTests (`loadStateFromPre`) |
| GeneralStateTests | Design only; no harness yet |
| BlockchainTests   | Not started |

## Integration Path

1. **Parse** — Add `validation/state_test_runner.zig` that parses GeneralStateTests JSON.
2. **Env → ExecutionRequest** — Map `env` fields to `sim.ExecutionRequest` / `evm.ExecutionContext`.
3. **Transaction execution** — Reuse `state.StateDB` + `evm.EVM.initWithState`. Need:
   - Transaction validation and sender recovery from `secretKey`
   - CREATE vs CALL dispatch (empty `to` → CREATE)
   - Gas accounting (gasPrice, intrinsic gas, etc.)
4. **Post-state check** — Compute state root (or compare account-by-account) and compare to `post`.
5. **Fork handling** — Select expected post by fork name; skip unsupported forks.

## Dependencies

- `ethereum-tests` repo: `git clone https://github.com/ethereum/tests ethereum-tests`
- GeneralStateTests live under `ethereum-tests/GeneralStateTests/`

## References

- [Ethereum Tests — General State Tests](https://ethereum-tests.readthedocs.io/en/latest/test_types/gstate_tests.html)
- [State Tests Format (EEST)](https://eest.ethereum.org/v5.3.0/running_tests/test_formats/state_test/)
- `validation/vm_test_runner.zig` — Reusable pre-state loading and VM execution
