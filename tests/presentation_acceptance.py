#!/usr/bin/env python3
"""Render current AppKit presentation with fake power; reject an omitted status icon."""
import hashlib
import json
from pathlib import Path
import platform
import plistlib
import subprocess
import sys
import tempfile
import uuid
ROOT = Path(__file__).resolve().parents[1]
ENTRY = r'''
import AppKit
@main enum Main {
 static func main() {
  let app = NSApplication.shared; app.setActivationPolicy(.accessory)
  let owner = MenuApp(); owner.engine.fixtureActionsAllowed = true
  owner.buildWindow(); owner.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  owner.permissionReady = true; owner.render()
  func walk(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(walk) }
  let icons = walk(owner.window.contentView!).compactMap { $0 as? NSImageView }
  guard icons.count >= 4 && icons.allSatisfy({ $0.image != nil }) else {
   fputs("FAIL: status icon and all three row symbols must remain visible\n", stderr); exit(1)
  }
  print("PASS: native status and all row symbols remain present")
 }
}
'''


def run(source):
    with tempfile.TemporaryDirectory(prefix='nosleep-presentation-') as directory:
        d = Path(directory); bundle = 'local.NoSleep.Presentation.' + uuid.uuid4().hex
        ui = source[source.index('final class MenuApp:'):source.index('@main enum NoSleepMain')]
        old = 'FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NoSleep")'
        ui = ui.replace(old, 'UIHarnessEnvironment.dataDirectory').replace('UserDefaults.standard', 'UIHarnessEnvironment.defaults')
        (d / 'UI.swift').write_text('import AppKit\n' + ui)
        (d / 'Entry.swift').write_text(ENTRY)
        (d / 'Aggregate.swift').write_text('func aggregateTitle(system: Bool, display: Bool) -> String { system || display ? "Выключить всё" : "Включить всё" }')
        app = d / 'Fixture.app'; exe = app / 'Contents/MacOS/Fixture'; exe.parent.mkdir(parents=True)
        inputs = [d/'UI.swift',d/'Entry.swift',d/'Aggregate.swift'] + [ROOT/p for p in ['tests/ui_harness/Stubs.swift','Sources/AutomaticLock.swift','Sources/ApplicationMenu.swift','Sources/Termination.swift','Sources/NoSleepBrand.swift','Sources/InterfaceMotion.swift','Sources/PowerPresentation.swift','Sources/TimedProtection.swift','Sources/DurationPopover.swift']]
        compile_result = subprocess.run(['swiftc','-module-cache-path',str(ROOT/'build/regression/module-cache'),*map(str, inputs),'-o',str(exe)],capture_output=True,text=True,timeout=90)
        assert compile_result.returncode == 0, compile_result.stderr
        (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':bundle,'CFBundleExecutable':'Fixture','CFBundlePackageType':'APPL'}))
        subprocess.run(['codesign','--force','--sign','-',str(app)],check=True,capture_output=True)
        (d/'application-support').mkdir()
        return subprocess.run([str(exe),str(d),bundle],capture_output=True,text=True,timeout=15)


def main():
    if platform.system() != 'Darwin':
        print('DEFERRED: native presentation requires macOS'); return
    path = Path(sys.argv[2]) if len(sys.argv) == 3 and sys.argv[1] == '--source' else ROOT/'Sources/NoSleep.swift'
    source = path.read_text(); result = run(source)
    assert result.returncode == 0, result.stdout + result.stderr
    before = 'NSStackView(views: [summaryIcon, summaryText])'
    assert source.count(before) == 1
    faulty = run(source.replace(before, 'NSStackView(views: [summaryText])'))
    assert faulty.returncode != 0 and 'FAIL: status icon and all three row symbols' in faulty.stderr, faulty.stdout + faulty.stderr
    output = ROOT/'build/icon-power-repair/presentation'; output.mkdir(parents=True,exist_ok=True)
    (output/'receipt.json').write_text(json.dumps({'result':'passed','sourceSHA256':hashlib.sha256(source.encode()).hexdigest(),'omittedIconMutantCaught':True,'realPowerActions':0},indent=2)+'\n')
    print('PASS: actual native presentation and omitted-icon mutant')


if __name__ == '__main__':main()
