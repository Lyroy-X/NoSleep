"""Regression guard against reintroducing credential or connection-command automation."""
from pathlib import Path
import subprocess,sys
root=Path(__file__).resolve().parents[1]
texts='\n'.join(p.read_text() for p in (root/'Sources').glob('*.swift'))
for forbidden in ['SecItemCopyMatching','SecItemAdd','SecItemUpdate','SecItemDelete','VPNCredentials','CiscoAuthentication','VPNRecoveryPolicy']:
    assert forbidden not in texts, 'Unsafe VPN capability returned: '+forbidden
observer=(root/'Sources/CiscoObserver.swift').read_text()
assert 'static let arguments = ["-s", "state"]' in observer
assert 'process.standardInput = FileHandle.nullDevice' in observer
assert 'fileHandleForWriting' not in observer and 'write(contentsOf:' not in observer
assert observer.count('Process()')==1
app=Path(sys.argv[1]).resolve() if len(sys.argv)>1 else root/'build/NoSleep.app'
symbols=subprocess.check_output(['nm','-u',str(app/'Contents/MacOS/NoSleep')],text=True)
for name in ['SecItemCopyMatching','SecItemAdd','SecItemUpdate','SecItemDelete']:assert name not in symbols
print('PASS: no credential APIs, no connection/authentication machinery, one fixed status command, EOF-only input')
