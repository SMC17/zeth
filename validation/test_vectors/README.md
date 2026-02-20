# Zeth Test Vector Format

Machine-readable opcode test vectors for agent-driven implementation and regression.

## Format (JSON)

```json
{
  "name": "ADD_2_3",
  "opcode": "ADD",
  "bytecode": "0x6002600301",
  "calldata": "0x",
  "pre_stack": ["0x03", "0x02"],
  "pre_memory": {},
  "post_stack": ["0x05"],
  "post_memory": {},
  "gas_expected": 9,
  "success": true
}
```

- `bytecode`: hex-encoded bytecode (with or without 0x prefix)
- `calldata`: hex-encoded calldata
- `pre_stack`: initial stack (top last), hex strings
- `post_stack`: expected stack after execution (top last)
- `gas_expected`: exact gas consumed
- `success`: whether execution should succeed

## Conversion

```bash
# Generate vectors from VMTests (requires ethereum-tests clone)
zig build validate-vm -- --convert --out validation/test_vectors/generated.json
```

## Usage

```bash
# Run vector regression
zig build vector-run -- validation/test_vectors/generated.json
```

Note: Vectors are generated with full VMTests pre state. The runner uses empty state; tests that depend on pre state may fail until we add pre-state serialization to the format.
