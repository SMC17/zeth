#!/usr/bin/env python3
"""
Simplified PyEVM executor - uses pyevm library's execute_code
"""

import sys
import json

def execute_bytecode(bytecode_hex: str, calldata_hex: str = "") -> dict:
    """
    Execute EVM bytecode using PyEVM - simplified version
    Returns dict with success, gas_used, return_data, stack, error
    """
    try:
        # For now, return a placeholder indicating PyEVM integration needs work
        # This allows the framework to compile and run, even if PyEVM execution fails
        return {
            "success": False,
            "gas_used": 0,
            "return_data": "0x",
            "stack": [],
            "error": "PyEVM executor API integration in progress - use manual testing for now",
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
            "error": "Usage: python3 pyevm_executor_simple.py <bytecode_hex> [calldata_hex]"
        }))
        sys.exit(1)
    
    bytecode_hex = sys.argv[1]
    calldata_hex = sys.argv[2] if len(sys.argv) > 2 else ""
    
    result = execute_bytecode(bytecode_hex, calldata_hex)
    print(json.dumps(result))

