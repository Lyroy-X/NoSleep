#!/usr/bin/env python3
"""Execute current native UI with isolated in-memory power dependencies."""
import argparse,hashlib,json,plistlib,subprocess,uuid
from pathlib import Path
root=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser();parser.add_argument('--no-screenshots',action='store_true');parser.parse_args()
case=root/'build/ui-acceptance'/uuid.uuid4().hex;case.mkdir(parents=True)
source=(root/'Sources/NoSleep.swift').read_text()
ui=source[source.index('final class MenuApp:'):source.index('@main enum NoSleepMain')]
old='FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NoSleep")'
assert ui.count(old)==1
ui=ui.replace(old,'UIHarnessEnvironment.dataDirectory').replace('UserDefaults.standard','UIHarnessEnvironment.defaults')
(case/'UI.swift').write_text('import AppKit\n'+ui)
bundle='local.NoSleep.UIFixture.'+uuid.uuid4().hex
app=case/'Fixture.app';exe=app/'Contents/MacOS/Fixture';exe.parent.mkdir(parents=True)
inputs=[case/'UI.swift',root/'tests/ui_harness/Stubs.swift',root/'tests/ui_harness/Entry.swift',root/'tests/ui_harness/TerminationAcceptance.swift',root/'Sources/ApplicationMenu.swift',root/'Sources/UITests.swift',root/'Sources/Termination.swift',root/'Sources/NoSleepBrand.swift']
(case/'Aggregate.swift').write_text('func aggregateTitle(system: Bool, display: Bool) -> String { system || display ? "Выключить всё" : "Включить всё" }\n');inputs.append(case/'Aggregate.swift')
result=subprocess.run(['swiftc','-module-cache-path',str(root/'build/module-cache/ui-rollback'),*map(str,inputs),'-o',str(exe)],capture_output=True,text=True,timeout=90)
(case/'compile.log').write_text(result.stdout+result.stderr)
assert result.returncode==0,result.stderr
symbols=subprocess.check_output(['nm','-u',str(exe)],text=True)
for forbidden in ['_SecItem','_IOPMAssertion','_AXUIElementPerformAction','_AXUIElementSetAttributeValue']:
 assert forbidden not in symbols,forbidden
(app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':bundle,'CFBundleExecutable':'Fixture','CFBundlePackageType':'APPL'}))
subprocess.run(['codesign','--force','--sign','-',str(app)],check=True,capture_output=True)
run=subprocess.run([str(exe),str(case),bundle],capture_output=True,text=True,timeout=30)
(case/'runtime.log').write_text(run.stdout+run.stderr)
assert run.returncode==0,run.stdout+run.stderr
assert "PASS: system quit cancellation and critical confirmation mutation" not in run.stdout, "UI fixture repeated the compiler-based regression instead of its own dialog tests"
receipt={'result':'passed','level':'e2e','scope':'current native UI with isolated power model','realPowerActions':0,'installedAppActions':0,'networkActions':0,'inputs':{str(p.relative_to(root)) if p.is_relative_to(root) else str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}}
(case/'receipt.json').write_text(json.dumps(receipt,indent=2))
print(run.stdout);print('Evidence:',case)
