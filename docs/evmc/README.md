# EVMC Interface

EVMC allows Zeth to plug into Geth, Reth, Besu, or L2 sequencers as a drop-in execution backend.

## Status

**Implemented (stub).** Build produces a loadable EVMC plugin.

- `zig build evmc` → `zig-out/lib/libzeth_evmc.so` (Linux) or `libzeth_evmc.dylib` (macOS)
- Exports `evmc_create_zeth()` returning `evmc_vm*` with destroy + execute
- Execute currently returns `EVMC_REJECTED` (stub); full implementation requires host bridge

## Integration Path

1. **Build** — `zig build evmc` produces `libzeth_evmc.so` (or `.dylib` on macOS)
2. **Export `evmc_load`** — Returns `evmc_instance*` (or `evmc_vm*` in EVMC 12+)
3. **Implement `execute`** — Map `evmc_message` → `sim.ExecutionRequest`, call `sim.execute`, map result → `evmc_result`
4. **Host bridge** — When client provides host context, use host callbacks for state (balance, storage, code) instead of internal StateDB

## EVMC Resources

- [EVMC repository](https://github.com/ethereum/evmc)
- [evmc.h](https://github.com/ethereum/evmc/blob/master/include/evmc/evmc.h)
- [Hera](https://github.com/ewasm/hera) — ewasm VM with EVMC; reference for host/VM split

## Build

```bash
zig build evmc
# Produces zig-out/lib/libzeth_evmc.so (Linux) or libzeth_evmc.dylib (macOS)
```

Client loads via `dlopen` / `LoadLibrary` and resolves `evmc_load`.
