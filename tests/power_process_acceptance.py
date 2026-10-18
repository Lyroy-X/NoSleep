#!/usr/bin/env python3
"""Execute the production power runner with harmless child processes only."""
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
ENTRY = r'''
@main enum RunnerContracts {
 static func main() {
  let runner = Runner(), helper = CommandLine.arguments[1]
  func large() {
   do {
    let text = try runner.run(helper, ["65536"])
    guard text.utf8.count == 65536 else { fatalError("wrong output size") }
   } catch {
    fputs("FAIL: power runner must isolate stdin and drain output before waiting for exit\n", stderr); exit(1)
   }
  }
  large()
  for mode in ["65537", "refuse", "timeout"] {
   let started = Date()
   do { _ = try runner.run(helper, [mode]); fputs("FAIL: refusal/limit/timeout was accepted\n", stderr); exit(1) }
   catch { assert(Date().timeIntervalSince(started) < 8, "Failure must stay bounded") }
  }
  do { _ = try runner.run("/nonexistent/NoSleep-fixture", []); fatalError("missing executable accepted") } catch {}
  large()
  print("PASS: exact output boundary, backpressure, refusal, timeout, missing command and retry")
 }
}
'''


def fixture(source, folder):
    lock = (ROOT / 'Sources/AutomaticLock.swift').read_text()
    dependencies = lock[lock.index('enum ScreenLockFailure'):lock.index('protocol ScreenLockCommandRunning')]
    method = source[source.index('    private func run(', source.index('final class MacPower')):source.index('    func canControlSleep()', source.index('final class MacPower'))]
    method = method.replace('private func run(', 'func run(')
    swift = folder / 'Runner.swift'
    swift.write_text('import Foundation\nimport Darwin\nstruct PowerError: LocalizedError { let message: String; var errorDescription: String? { message } }\n'
                     + dependencies + '\nfinal class Runner {\n' + method + '}\n' + ENTRY)
    result = subprocess.run(['swiftc', '-parse-as-library', '-module-cache-path', str(ROOT / 'build/regression/module-cache'),
                             str(swift), '-o', str(folder / 'runner')], capture_output=True, text=True, timeout=90)
    assert result.returncode == 0, result.stderr
    helper = folder / 'child'
    helper.write_text('#!' + sys.executable + '\nimport os,sys,time\n'
                      'mode=sys.argv[1]\n'
                      'if mode=="refuse": sys.exit(7)\n'
                      'if mode=="timeout": time.sleep(12); sys.exit(0)\n'
                      'count=int(mode)\n'
                      'while count:\n n=os.write(2,b"x"*min(count,4096)); count-=n\n'
                      'sys.stdin.read()\n')
    helper.chmod(0o700)
    log = folder / 'result.log'
    with log.open('w') as stream:
        process = subprocess.Popen([str(folder / 'runner'), str(helper)], stdin=subprocess.PIPE, stdout=stream, stderr=stream, text=True)
        try:
            code = process.wait(timeout=25)
        finally:
            process.stdin.close()
            if process.poll() is None:
                process.kill(); process.wait()
    return subprocess.CompletedProcess(process.args, code, '', log.read_text())


def main():
    if platform.system() != 'Darwin':
        print('DEFERRED: native power process contracts require macOS')
        return
    output = ROOT / 'build/icon-power-repair/process-contracts'
    output.mkdir(parents=True, exist_ok=True)
    path = Path(sys.argv[2]) if len(sys.argv) == 3 and sys.argv[1] == '--source' else ROOT / 'Sources/NoSleep.swift'
    source = path.read_text()
    with tempfile.TemporaryDirectory(prefix='nosleep-power-runner-') as directory:
        result = fixture(source, Path(directory))
    (output / ('baseline.log' if path != ROOT / 'Sources/NoSleep.swift' else 'candidate.log')).write_text(result.stdout + result.stderr)
    assert result.returncode == 0, result.stdout + result.stderr
    # Construct the critical faulty copy entirely from the candidate: restore waiting
    # before draining. No dependency on ignored baseline artifacts in CI.
    start = source.index('    private func run(', source.index('final class MacPower'))
    end = source.index('    func canControlSleep()', start)
    faulty = source[:start] + '''    private func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = output; process.standardError = output
        let done = DispatchSemaphore(value: 0); process.terminationHandler = { _ in done.signal() }
        try process.run()
        if done.wait(timeout: .now() + 5) == .timedOut {
            process.terminate(); throw PowerError(message: "timeout")
        }
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
''' + source[end:]
    with tempfile.TemporaryDirectory(prefix='nosleep-power-runner-mutant-') as directory:
        mutant = fixture(faulty, Path(directory))
    (output / 'mutant.log').write_text(mutant.stdout + mutant.stderr)
    assert mutant.returncode != 0 and 'FAIL: power runner must isolate stdin' in mutant.stderr, mutant.stdout + mutant.stderr
    (output / 'receipt.json').write_text(json.dumps({'result': 'passed', 'sourceSHA256': hashlib.sha256(source.encode()).hexdigest(),
                                                    'realPowerActions': 0, 'cases': ['normal', '65536-byte-boundary', '65537-byte-limit', 'refusal', 'timeout', 'missing', 'retry'],
                                                    'criticalInputOutputMutantCaught': True}, indent=2) + '\n')
    print('PASS: actual power process runner, bounded output/refusal/timeout/retry and critical input/output mutant')


if __name__ == '__main__':
    main()
