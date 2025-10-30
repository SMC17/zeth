#!/usr/bin/env python3
"""
PyEVM bytecode executor for Zeth reference testing
Uses state.apply_message with proper transaction wrapping
"""

import sys
import json
from eth.vm.forks.berlin import BerlinState
from eth.db.backends.memory import MemoryDB
from eth.constants import ZERO_ADDRESS, BLANK_ROOT_HASH
from eth_utils import to_canonical_address
from eth.vm.execution_context import ExecutionContext
from eth.vm.message import Message

def execute_bytecode(bytecode_hex: str, calldata_hex: str = "") -> dict:
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
                "error": "Invalid bytecode hex length",
            }
        bytecode = bytes.fromhex(bytecode_str)
        
        calldata_str = calldata_hex.replace("0x", "") if calldata_hex else ""
        calldata = bytes.fromhex(calldata_str) if calldata_str else b""
        
        # Create in-memory database
        db = MemoryDB()
        
        # Create execution context (minimal for bytecode execution)
        execution_context = ExecutionContext(
            coinbase=to_canonical_address(ZERO_ADDRESS),
            timestamp=0,
            block_number=0,
            difficulty=0,
            gas_limit=1000000,
            prev_hashes=(),
            chain_id=1,
            mix_hash=b'\x00' * 32,  # Required for Berlin fork
        )
        
        # Create state directly
        state = BerlinState(db, execution_context, BLANK_ROOT_HASH)
        
        # Create message for execution
        message = Message(
            gas=1000000,
            to=to_canonical_address(ZERO_ADDRESS),
            sender=to_canonical_address(ZERO_ADDRESS),
            value=0,
            data=calldata,
            code=bytecode,
        )
        
        # Create a transaction object that state.costless_execute_transaction expects
        # It needs: gas_price, and a copy() method that returns a transaction with updated gas_price
        class SimpleTransaction:
            def __init__(self, message):
                self.gas_price = 0
                self.message = message
                self.nonce = 0
                self.value = 0
                self.data = message.data
                self.to = message.to
                self.sender = message.sender
                self.gas = message.gas
            
            def copy(self, **kwargs):
                new = SimpleTransaction(self.message)
                for k, v in kwargs.items():
                    setattr(new, k, v)
                return new
        
        transaction = SimpleTransaction(message)
        
        # Execute via costless_execute_transaction
        computation = state.costless_execute_transaction(transaction)
        
        if computation.is_error:
            return {
                "success": False,
                "gas_used": computation.get_gas_used(),
                "return_data": "0x",
                "stack": [],
                "error": str(computation.error),
            }
        
        # Extract return data
        return_data = computation.output or b""
        return_data_hex = "0x" + return_data.hex() if return_data else "0x"
        
        return {
            "success": True,
            "gas_used": computation.get_gas_used(),
            "return_data": return_data_hex,
            "stack": [],  # Stack not directly accessible
            "error": None,
        }
        
    except Exception as e:
        import traceback
        return {
            "success": False,
            "gas_used": 0,
            "return_data": "0x",
            "stack": [],
            "error": f"{type(e).__name__}: {str(e)}\n{traceback.format_exc()}",
        }

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(json.dumps({
            "success": False,
            "error": "Usage: python3 pyevm_executor_v3.py <bytecode_hex> [calldata_hex]"
        }))
        sys.exit(1)
    
    bytecode_hex = sys.argv[1]
    calldata_hex = sys.argv[2] if len(sys.argv) > 2 else ""
    
    result = execute_bytecode(bytecode_hex, calldata_hex)
    print(json.dumps(result))
