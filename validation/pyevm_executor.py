#!/usr/bin/env python3
"""
PyEVM bytecode executor for Zeth reference testing
Uses BerlinComputation.apply_message to execute bytecode
"""

import sys
import json
from eth.vm.message import Message
from eth.constants import ZERO_ADDRESS
from eth.db.backends.memory import MemoryDB
from eth.vm.forks.berlin import BerlinState
from eth.vm.execution_context import ExecutionContext
from eth.constants import BLANK_ROOT_HASH
from eth_utils import to_canonical_address
from eth.vm.transaction_context import BaseTransactionContext
from eth.vm.forks.berlin.computation import BerlinComputation

def _serialize_stack(computation) -> list[str]:
    stack_obj = getattr(computation, "_stack", None) or getattr(computation, "stack", None)
    if stack_obj is None:
        return []

    raw_values = None
    for attr in ("values", "_values"):
        raw_values = getattr(stack_obj, attr, None)
        if raw_values is not None:
            break
    if raw_values is None and isinstance(stack_obj, (list, tuple)):
        raw_values = stack_obj
    if raw_values is None:
        return []

    serialized = []
    for item in list(raw_values):
        if isinstance(item, int):
            serialized.append(hex(item))
        elif isinstance(item, (bytes, bytearray)):
            serialized.append("0x" + bytes(item).hex())
    return serialized


def execute_bytecode(bytecode_hex: str, calldata_hex: str = "", state_payload_json: str = "") -> dict:
    """
    Execute EVM bytecode using PyEVM
    Returns dict with success, gas_used, return_data, stack, error
    """
    try:
        # Convert hex strings to bytes
        bytecode_str = bytecode_hex.replace("0x", "")
        if len(bytecode_str) % 2 != 0:
            return {
                "success": False,
                "gas_used": 0,
                "return_data": "0x",
                "stack": [],
                "storage": [],
                "error": "Invalid bytecode hex length",
            }
        bytecode = bytes.fromhex(bytecode_str)
        
        calldata_str = calldata_hex.replace("0x", "") if calldata_hex else ""
        calldata = bytes.fromhex(calldata_str) if calldata_str else b""
        
        # Create in-memory database
        db = MemoryDB()
        
        payload = json.loads(state_payload_json) if state_payload_json else {}

        # Create execution context
        execution_context = ExecutionContext(
            coinbase=to_canonical_address(ZERO_ADDRESS),
            timestamp=0,
            block_number=0,
            difficulty=0,
            gas_limit=1000000,
            prev_hashes=(),
            chain_id=1,
            mix_hash=b'\x00' * 32,
        )
        
        # Create state
        state = BerlinState(db, execution_context, BLANK_ROOT_HASH)
        tracked_storage = payload.get("tracked_storage_keys", [])
        account = to_canonical_address(ZERO_ADDRESS)
        for entry in payload.get("pre_storage", []):
            state.set_storage(account, int(entry["key"], 16), int(entry["value"], 16))
        
        # Create message for execution
        message = Message(
            to=to_canonical_address(ZERO_ADDRESS),
            sender=to_canonical_address(ZERO_ADDRESS),
            value=0,
            data=calldata,
            code=bytecode,
            gas=1000000,
        )
        
        # Create transaction context
        tx_context = BaseTransactionContext(
            gas_price=0,
            origin=to_canonical_address(ZERO_ADDRESS),
        )
        
        # Execute computation using BerlinComputation.apply_message
        # This is the correct way to execute bytecode in PyEVM
        computation = BerlinComputation.apply_message(state, message, tx_context)
        
        if computation.is_error:
            return {
                "success": False,
                "gas_used": computation.get_gas_used(),
                "return_data": "0x",
                "stack": [],
                "storage": [],
                "error": str(computation.error),
            }
        
        # Extract return data
        return_data = computation.output or b""
        return_data_hex = "0x" + return_data.hex() if return_data else "0x"
        
        return {
            "success": computation.is_success,
            "gas_used": computation.get_gas_used(),
            "return_data": return_data_hex,
            "stack": _serialize_stack(computation),
            "storage": [
                {
                    "key": key_hex,
                    "value": hex(state.get_storage(account, int(key_hex, 16))),
                }
                for key_hex in tracked_storage
            ],
            "error": None,
        }
        
    except Exception as e:
        import traceback
        return {
            "success": False,
            "gas_used": 0,
            "return_data": "0x",
            "stack": [],
            "storage": [],
            "error": f"{type(e).__name__}: {str(e)}\n{traceback.format_exc()}",
        }

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(json.dumps({
            "success": False,
            "storage": [],
            "error": "Usage: python3 pyevm_executor.py <bytecode_hex> [calldata_hex]"
        }))
        sys.exit(1)
    
    bytecode_hex = sys.argv[1]
    calldata_hex = sys.argv[2] if len(sys.argv) > 2 else ""
    state_payload_json = sys.argv[3] if len(sys.argv) > 3 else ""
    
    result = execute_bytecode(bytecode_hex, calldata_hex, state_payload_json)
    print(json.dumps(result))
