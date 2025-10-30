# PyEVM Setup Instructions

## Quick Setup

### Option 1: Install via pip (Recommended)
```bash
pip3 install eth-py-evm
```

### Option 2: Install from source
```bash
git clone https://github.com/ethereum/py-evm.git
cd py-evm
pip3 install -e .
```

### Verify Installation
```bash
python3 -c "import eth; from eth.vm.forks import BerlinVM; print('PyEVM installed successfully')"
```

## Troubleshooting

### If pip install fails:
1. Ensure Python 3.8+ is installed: `python3 --version`
2. Try upgrading pip: `pip3 install --upgrade pip`
3. Install dependencies: `pip3 install eth-utils eth-typing`

### If import fails:
- Check Python path: `python3 -c "import sys; print(sys.path)"`
- Verify virtual environment (if using one)
- Try: `python3 -m pip install eth-py-evm`

## Test Setup

After installing, run:
```bash
cd /Users/seancollins/eth
python3 validation/pyevm_executor.py 6005600301 ""
```

This should execute ADD opcode (PUSH1 5, PUSH1 3, ADD) and return JSON result.

## Alternative: Manual Testing

If PyEVM installation is problematic, you can:
1. Use Geth instead (if available)
2. Test against Ethereum test vectors
3. Use manual verification for now

The framework will gracefully handle PyEVM not being available.

