#!/usr/bin/env python3
"""Execute current native UI with isolated in-memory power dependencies."""
import argparse,hashlib,json,plistlib,subprocess,uuid,platform,os
from pathlib import Path
root=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser();parser.add_argument('--no-screenshots',action='store_true');parser.add_argument('--readiness-only',action='store_true');parser.add_argument('--lifecycle',action='store_true');parser.add_argument('--mutate-quit',action='store_true');parser.add_argument('--missing-permission',action='store_true');args=parser.parse_args()
if platform.system() != 'Darwin':
 print('DEFERRED: native UI acceptance requires the dependent macOS regression lanes')
 raise SystemExit(0)
case=root/'build/ui-acceptance'/uuid.uuid4().hex;case.mkdir(parents=True)
bundle='local.NoSleep.UIFixture.'+uuid.uuid4().hex
source=(root/'Sources/NoSleep.swift').read_text()
ui=source[source.index('final class MenuApp:'):source.index('@main enum NoSleepMain')]
old='FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NoSleep")'
assert ui.count(old)==1
ui=ui.replace(old,'UIHarnessEnvironment.dataDirectory').replace('UserDefaults.standard','UIHarnessEnvironment.defaults').replace('local.robert.NoSleep.command',bundle+'.command')
if args.mutate_quit:
 start=ui.index('    @objc func quitApp()')
 end=ui.index('    func applicationShouldHandleReopen',start)
 ui=ui[:start]+'    @objc func quitApp() { NSApplication.shared.terminate(nil) }\n'+ui[end:]
(case/'UI.swift').write_text('import AppKit\n'+ui)
app=case/'Fixture.app';exe=app/'Contents/MacOS/Fixture';exe.parent.mkdir(parents=True)
inputs=[case/'UI.swift',root/'tests/ui_harness/Stubs.swift',root/('tests/ui_harness/LifecycleEntry.swift' if args.lifecycle else 'tests/ui_harness/Entry.swift'),root/'tests/ui_harness/TerminationAcceptance.swift',root/'tests/ui_harness/AutomaticLockAcceptance.swift',root/'Sources/AutomaticLock.swift',root/'Sources/AutomaticLockTests.swift',root/'Sources/ApplicationMenu.swift',root/'Sources/UITests.swift',root/'Sources/Termination.swift',root/'Sources/NoSleepBrand.swift',root/'Sources/InterfaceMotion.swift',root/'Sources/PowerPresentation.swift',root/'Sources/PresentationTests.swift',root/'Sources/TimedProtection.swift',root/'Sources/DurationPopover.swift',root/'tests/ui_harness/TimedAcceptance.swift']
(case/'Aggregate.swift').write_text('func aggregateTitle(system: Bool, display: Bool) -> String { system || display ? "Выключить всё" : "Включить всё" }\n');inputs.append(case/'Aggregate.swift')
module_cache=Path(os.environ.get('NOSLEEP_UI_MODULE_CACHE',str(root/'build/module-cache/ui-rollback')))
fixture_flags=[] if args.lifecycle else ['-D','NOSLEEP_UI_FIXTURE']
result=subprocess.run(['swiftc',*fixture_flags,'-module-cache-path',str(module_cache),*map(str,inputs),'-o',str(exe)],capture_output=True,text=True,timeout=90)
(case/'compile.log').write_text(result.stdout+result.stderr)
assert result.returncode==0,result.stderr
symbols=subprocess.check_output(['nm','-u',str(exe)],text=True)
for forbidden in ['_SecItem','_IOPMAssertion','_AXUIElementPerformAction','_AXUIElementSetAttributeValue']:
 assert forbidden not in symbols,forbidden
(app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':bundle,'CFBundleExecutable':'Fixture','CFBundlePackageType':'APPL'}))
subprocess.run(['codesign','--force','--sign','-',str(app)],check=True,capture_output=True)
try:
 run=subprocess.run([str(exe),str(case),bundle]+(['--readiness-only'] if args.readiness_only else [])+(['--lifecycle'] if args.lifecycle else [])+(['--missing-permission'] if args.missing_permission else []),capture_output=True,text=True,timeout=40 if args.lifecycle else 30)
except subprocess.TimeoutExpired as failure:
 partial=(failure.stdout or b'')+(failure.stderr or b'')
 (case/'runtime.log').write_bytes(partial)
 raise AssertionError('Native fixture timed out; partial runtime output:\n'+partial.decode(errors='replace')) from failure
runtime=run.stdout+run.stderr
(case/'runtime.log').write_text(runtime)
assert run.returncode==0,runtime
assert "PASS: system quit cancellation and critical confirmation mutation" not in run.stdout
if args.lifecycle:assert (case/'lifecycle-result.txt').read_text()=='passed'
receipt={'result':'passed','level':'targeted-native' if args.readiness_only else 'e2e','driver':'native-app-lifecycle' if args.lifecycle else 'native-fixture','scope':'current native UI with isolated power model','realPowerActions':0,'installedAppActions':0,'networkActions':0,'inputs':{str(p.relative_to(root)) if p.is_relative_to(root) else str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}}
(case/'receipt.json').write_text(json.dumps(receipt,indent=2))
print(runtime);print('Evidence:',case)
