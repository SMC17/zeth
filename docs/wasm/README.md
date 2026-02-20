# zeth-wasm: Browser/Edge EVM

Client-side EVM execution via WebAssembly for transaction simulation without RPC.

## Build

```bash
zig build wasm
```

Produces `zig-out/lib/zeth_evm.wasm` (wasm32-wasi target).

## FFI

Export: `zeth_execute(input_ptr, input_len, output_ptr, output_cap) -> u32`

- **Input** (linear memory at `input_ptr`, length `input_len`):
  - `[0..4]`: `code_len` (u32 little-endian)
  - `[4..4+code_len]`: bytecode
  - `[4+code_len..8+code_len]`: `calldata_len` (u32 LE)
  - `[8+code_len..]`: calldata bytes

- **Output** (written to `output_ptr`, max `output_cap` bytes):
  - `[0]`: success (1 = ok, 0 = revert/failure)
  - `[1..9]`: gas_used (u64 LE)
  - `[9..13]`: return_data_len (u32 LE)
  - `[13..13+return_data_len]`: return data

- **Return value**: total bytes written, or `0xFFFFFFFF` on error (parse/OOM).

## JavaScript Example

```javascript
const wasm = await WebAssembly.instantiateStreaming(fetch('zeth_evm.wasm'));
const { zeth_execute, memory } = wasm.instance.exports;

function executeEvm(bytecode, calldata = new Uint8Array(0)) {
  const codeLen = new Uint8Array(4);
  new DataView(codeLen.buffer).setUint32(0, bytecode.length, true);
  const calldataLen = new Uint8Array(4);
  new DataView(calldataLen.buffer).setUint32(0, calldata.length, true);
  const input = new Uint8Array([...codeLen, ...bytecode, ...calldataLen, ...calldata]);
  const outBuf = new Uint8Array(1024);
  const mem = new Uint8Array(memory.buffer);
  mem.set(input, 0x1000);
  const n = zeth_execute(0x1000, input.length, 0x2000, outBuf.length);
  if (n === 0xFFFFFFFF) return null;
  return {
    success: mem[0x2000] === 1,
    gas_used: new DataView(memory.buffer).getBigUint64(0x2001, true),
    returnData: mem.slice(0x200D, 0x200D + new DataView(memory.buffer).getUint32(0x2009, true)),
  };
}
```

## Run with wasmtime

```bash
# zeth_execute is exported; use a host to pass pointers
wasmtime zig-out/lib/zeth_evm.wasm --invoke zeth_execute 0 0 0 0
```
