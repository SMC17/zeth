#!/usr/bin/env python3
"""
PyEVM bytecode executor for Zeth reference testing
Updated for PyEVM 0.12 API
"""

import sys
import json
from eth.vm.forks.berlin import BerlinVM, BerlinState
from eth.db.backends.memory import MemoryDB
from eth.constants import ZERO_ADDRESS
from eth_utils import to_canonical_address, encode_hex

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
        
        # Use MainnetChain with proper genesis initialization
        from eth.chains.mainnet import MainnetChain
        from eth.constants import GENESIS_PARENT_HASH
        
        # Create genesis parameters
        genesis_params = {
            'parent_hash': GENESIS_PARENT_HASH,
            'coinbase': b'\x00' * 20,
            'state_root': b'\x00' * 32,
            'transaction_root': b'\x00' * 32,
            'receipt_root': b'\x00' * 32,
            'bloom': 0,
            'difficulty': 17179869184,
            'block_number': 0,
            'gas_limit': 5000,
            'gas_used': 0,
            'timestamp': 0,
            'extra_data': b'',
            'mix_hash': b'\x00' * 32,
            'nonce': b'\x00' * 8,
        }
        
        # Create chain from genesis
        chain = MainnetChain.from_genesis(db, genesis_params)
        
        # Get VM state from chain
        state = chain.get_vm().get_state()
        
        # Execute bytecode using state
        computation = state.execute_bytecode(
            origin=to_canonical_address(ZERO_ADDRESS),
            gas_price=0,
            gas=1000000,
            to=to_canonical_address(ZERO_ADDRESS),
            sender=to_canonical_address(ZERO_ADDRESS),
            value=0,
            data=calldata,
            code=bytecode,
        )
        
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
            "error": "Usage: python3 pyevm_executor_v2.py <bytecode_hex> [calldata_hex]"
        }))
        sys.exit(1)
    
    bytecode_hex = sys.argv[1]
    calldata_hex = sys.argv[2] if len(sys.argv) > 2 else ""
    
    result = execute_bytecode(bytecode_hex, calldata_hex)
    print(json.dumps(result))

