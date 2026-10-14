"""Verify the built app has no VPN, Keychain or accessibility automation."""
from pathlib import Path
import subprocess,sys
root=Path(__file__).resolve().parents[1]
texts='\n'.join(p.read_text() for p in (root/'Sources').glob('*.swift'))
for forbidden in ['CiscoObserver','CiscoConnectionClient','VPNCredentialStore','VPNSettingsController','SecItemCopyMatching','SecItemAdd','SecItemUpdate','SecItemDelete','AXUIElementPerformAction','AXUIElementSetAttributeValue','"connect"','"disconnect"']:
 assert forbidden not in texts,forbidden
app=Path(sys.argv[1]).resolve() if len(sys.argv)>1 else root/'build/NoSleep.app'
symbols=subprocess.check_output(['nm','-u',str(app/'Contents/MacOS/NoSleep')],text=True)
for forbidden in ['_SecItem','_AXUIElement','_SCNetwork','_nw_path_monitor']:
 assert forbidden not in symbols,forbidden
print('PASS: built app has no Cisco, credentials, VPN commands or accessibility automation')
