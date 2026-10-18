#!/usr/bin/env python3
"""Exercise the exact quit scheduler with a fake termination boundary."""
from pathlib import Path
import json
import platform
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parents[1]
ENTRY = r'''
enum TerminationProbe {
 static var owner: MenuApp!
 static var calls = 0, depth = 0, maximumDepth = 0
 static func terminate() {
  calls += 1; depth += 1; maximumDepth = max(depth, maximumDepth)
  guard depth == 1 else {
   fputs("FAIL: fresh quit must wait until prior termination unwinds\n", stderr); exit(1)
  }
  if calls == 1 {
   owner.quitApp() // a fresh request while cancellation is still unwinding
   RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
  }
  depth -= 1
 }
}
@main enum Main {
 static func main() {
  setbuf(stdout, nil); print("START: exact scheduler fixture")
  let owner = MenuApp(); TerminationProbe.owner = owner
  func wait(_ count: Int) {
   let until = Date(timeIntervalSinceNow: 1)
   while TerminationProbe.calls < count && Date() < until { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005)) }
  }
  owner.quitApp(); wait(2)
  guard TerminationProbe.calls == 2 && TerminationProbe.maximumDepth == 1 else {
   fputs("FAIL: fresh quit must wait until prior termination unwinds\n", stderr); exit(1)
  }
  owner.handlingTermination = true; owner.quitApp()
  RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
  assert(TerminationProbe.calls == 2, "A pending confirmation refuses another quit")
  owner.handlingTermination = false
  owner.quitApp(); owner.quitApp(); wait(3)
  assert(TerminationProbe.calls == 3 && TerminationProbe.maximumDepth == 1, "Repeated scheduled quits coalesce and retry remains available")
  print("PASS: exact quit scheduler, unwinding, refusal, duplicate coalescing and retry")
 }
}
'''


def run(source, faulty=False):
    start=source.index('    @objc func quitApp()');end=source.index('    func applicationShouldHandleReopen',start)
    methods=source[start:end].replace('NSApplication.shared.terminate(nil)','TerminationProbe.terminate()')
    if faulty:
        assert methods.count('guard let self, !self.quitInProgress else { return }')==1
        methods=methods.replace('guard let self, !self.quitInProgress else { return }','guard let self else { return }')
    fields='\n'.join(line.replace('private ','') for line in source.splitlines() if any('var '+name+' ' in line for name in ['handlingTermination','quitScheduled','quitInProgress']))
    with tempfile.TemporaryDirectory(prefix='nosleep-quit-routing-') as directory:
        d=Path(directory);swift=d/'Entry.swift';exe=d/'fixture'
        swift.write_text('import AppKit\nfinal class MenuApp: NSObject {\n'+fields+'\n'+methods+'}\n'+ENTRY)
        compiled=subprocess.run(['swiftc','-parse-as-library','-module-cache-path',str(ROOT/'build/regression/module-cache'),str(swift),'-o',str(exe)],capture_output=True,text=True,timeout=90)
        assert compiled.returncode==0,compiled.stderr
        return subprocess.run([str(exe)],capture_output=True,text=True,timeout=20)


def main():
    if platform.system()!='Darwin': print('DEFERRED: native quit scheduler requires macOS');return
    source=(ROOT/'Sources/NoSleep.swift').read_text();normal=run(source)
    assert normal.returncode==0,normal.stdout+normal.stderr
    faulty=run(source,True)
    assert faulty.returncode!=0 and 'FAIL: fresh quit must wait' in faulty.stderr,faulty.stdout+faulty.stderr
    out=ROOT/'build/icon-power-repair/quit-routing';out.mkdir(parents=True,exist_ok=True)
    (out/'normal.log').write_text(normal.stdout+normal.stderr);(out/'mutant.log').write_text(faulty.stdout+faulty.stderr)
    (out/'receipt.json').write_text(json.dumps({'result':'passed','nestedQuitMutantCaught':True,'realApplicationTermination':False},indent=2)+'\n')
    print('PASS: production quit scheduler and deterministic nested-quit mutant')


if __name__=='__main__':main()
