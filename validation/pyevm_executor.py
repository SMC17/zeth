#!/usr/bin/env python3
"""
PyEVM bytecode executor for Zeth reference testing
Executes EVM bytecode and returns structured results
"""

import sys
import json
from eth import constants
from eth.vm import VM
from eth.vm.forks import BerlinVM
from eth.vm.message import Message
from eth.vm.state import BlockChainDB
from eth.constants import ZERO_ADDRESS
from eth.db.backends.memory import MemoryDB

def execute_bytecode(bytecode_hex: str, calldata_hex: str = "") -> dict:
    """
    Execute EVM bytecode using PyEVM
    Returns dict with success, gas_used, return_data, stack, error
    """
    try:
        # Convert hex strings to bytes
        bytecode = bytes.fromhex(bytecode_hex.replace("0x", ""))
        calldata = bytes.fromhex(calldata_hex.replace("0x", "")) if calldata_hex else b""
        
        # Create in-memory database
        db = MemoryDB()
        chaindb = BlockChainDB(db)
        
        # Create VM (Berlin fork - supports EIP-2929, EIP-2200)
        vm = BerlinVM(chaindb)
        
        # Create message for execution
        message = Message(
            to=ZERO_ADDRESS,
            sender=ZERO_ADDRESS,
            value=0,
            data=calldata,
            code=bytecode,
            gas=1000000,
        )
        
        # Create transaction context
        tx_context = vm.create_transaction_context(
            message=message,
            transaction=message,
        )
        
        # Execute
        computation = vm.execute_computation(message, tx_context)
        
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
        return_data_hex = "0x" + return_data.hex()
        
        # Extract stack (simplified - PyEVM doesn't expose stack directly)
        # We'd need to modify execution to capture stack
        stack = []
        
        return {
            "success": True,
            "gas_used": computation.get_gas_used(),
            "return_data": return_data_hex,
            "stack": stack,
            "error": None,
        }
        
    except Exception as e:
        return {
            "success": False,
            "gas_used": 0,
            "return_data": "0x",
            "stack": [],
            "error": str(e),
        }

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(json.dumps({
            "success": False,
            "error": "Usage: python3 pyevm_executor.py <bytecode_hex> [calldata_hex]"
        }))
        sys.exit(1)
    
    bytecode_hex = sys.argv[1]
    calldata_hex = sys.argv[2] if len(sys.argv) > 2 else ""
    
    result = execute_bytecode(bytecode_hex, calldata_hex)
    print(json.dumps(result))

