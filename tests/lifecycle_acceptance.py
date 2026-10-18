#!/usr/bin/env python3
"""Run the real AppKit event loop with isolated power/password dependencies."""
from pathlib import Path
import subprocess
import sys
root = Path(__file__).resolve().parents[1]
subprocess.run([sys.executable, str(root / 'tests/ui_acceptance.py'), '--lifecycle'], check=True)

subprocess.run([sys.executable, str(root / 'tests/ui_acceptance.py'), '--lifecycle', '--missing-permission'], check=True)
faulty = subprocess.run([sys.executable, str(root / 'tests/ui_acceptance.py'), '--lifecycle', '--mutate-quit'], capture_output=True, text=True)
assert faulty.returncode != 0 and 'FAIL: async quit must present its sheet' in faulty.stderr, faulty.stdout + faulty.stderr
print('PASS: faulty main-dispatch quit is caught by the native lifecycle assertion')
