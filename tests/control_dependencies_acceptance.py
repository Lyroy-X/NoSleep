#!/usr/bin/env python3
"""Exercise the real power model, private preferences and critical faulty copies."""
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CONTRACTS = r'''
import Foundation
@main enum Contracts {
    static func main() throws {
        let domain = "NoSleep.DependencyFixture." + String(getpid())
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let power = FakePower(), engine = GuardEngine(FakePower())
        let checked = GuardEngine(power)
        func act(_ command: String, save: Bool = true) -> LiveState {
            let done = DispatchSemaphore(value: 0)
            checked.act(command, save: save) { done.signal() }
            assert(done.wait(timeout: .now() + 3) == .success, "Fixture action timed out")
            return checked.queue.sync { checked.state() }
        }
        func persisted(_ state: LiveState) {
            assert(defaults.bool(forKey: "PreventSystemSleep") == state.systemWanted,
                   "Partial system outcome must persist after failure")
            assert(defaults.bool(forKey: "KeepDisplayAwake") == state.displayWanted,
                   "Partial display outcome must persist after failure")
        }
        defaults.set(false, forKey: "PreventSystemSleep")
        defaults.set(false, forKey: "KeepDisplayAwake")
        power.reject = true
        var state = act("display-on")
        assert(!state.systemWanted && !state.displayWanted && !state.displayActual && state.error != nil,
               "Refused prerequisite must not acquire dependent display")
        persisted(state)
        power.reject = false; power.rejectDisplay = true
        state = act("all-on")
        assert(state.systemWanted && state.systemActual && !state.displayWanted && state.error != nil)
        persisted(state)
        power.rejectDisplay = false
        state = act("display-on")
        assert(state.systemWanted && state.displayWanted && state.error == nil)
        persisted(state)
        power.reject = true
        state = act("sleep-off")
        assert(state.systemWanted && state.displayWanted && state.displayActual && state.error != nil,
               "Refused system restoration must retain dependent display")
        persisted(state)
        power.reject = false
        state = act("sleep-off")
        assert(!state.systemWanted && !state.displayWanted && !state.displayActual && state.error == nil)
        persisted(state)
        _ = act("display-on", save: false)
        assert(!defaults.bool(forKey: "PreventSystemSleep") && !defaults.bool(forKey: "KeepDisplayAwake"),
               "Explicit no-save actions must leave private preferences unchanged")
        _ = act("all-off")
        state = act("unknown")
        assert(state.error != nil && !state.systemWanted && !state.displayWanted)
        state = act("sleep-on")
        assert(state.error == nil && state.systemWanted && !state.displayWanted, "Failure must remain retryable")
        _ = act("all-off")
        assert(LiveState(systemWanted: true, systemActual: true, displayWanted: true,
                         displayActual: false, error: nil).statusTitle == " !",
               "Selected missing display must flag the shared status")
        // Empty, repeatable cleanup on another real engine remains isolated.
        try engine.shutdownNow(); try engine.shutdownNow()
        print("PASS: actual power model, partial preferences, refusal/retry, no-save, unknown input and shared status")
    }
}
'''


def main():
    if platform.system() != "Darwin":
        print("DEFERRED: real Swift model contracts run in both macOS native lanes")
        return
    output = ROOT / "build/control-dependencies/acceptance"
    output.mkdir(parents=True, exist_ok=True)
    if "--ui-mutations" in sys.argv:
        ui_mutations(output)
        return
    source = (ROOT / "Sources/NoSleep.swift").read_text()
    # Extract production definitions, not a second model. No MacPower/IOKit code is linked.
    model = ((ROOT / 'Sources/TimedProtection.swift').read_text() + "\nimport Foundation\n" + source[source.index("protocol PowerControl"):source.index("func waitForPowerState")]
             + source[source.index("final class Protection"):source.index("func selfTest()")]
             + source[source.index("struct LiveState:"):source.index("func backgroundTest()")])
    model = model.replace("UserDefaults.standard", 'UserDefaults(suiteName: "NoSleep.DependencyFixture." + String(getpid()))!')
    mutants = [
        ("prerequisite-refusal", "if !active { try enable() }\n            else if try !power.blocked() { try enable() }",
         "try? enable()"),
        ("restore-refusal", "try power.setBlocked(false)", "power.releaseDisplay(); try power.setBlocked(false)"),
        ("partial-persistence", "if save {", "if save && self.actionError == nil {"),
        ("missing-confirmation", " || (systemWanted && !systemActual) || (displayWanted && !displayActual)", ""),
    ]
    receipts = []
    with tempfile.TemporaryDirectory(dir=output, prefix="fixture-") as directory:
        case = Path(directory)
        (case / "Contracts.swift").write_text(CONTRACTS)
        for name, before, after in [("unmodified", "", ""), *mutants]:
            if before:
                assert model.count(before) == 1, name
            (case / "Model.swift").write_text(model.replace(before, after, 1) if before else model)
            compiled = subprocess.run(["swiftc", "-module-cache-path", str(output / "module-cache"),
                                       str(case / "Model.swift"), str(case / "Contracts.swift"), "-o", str(case / "fixture")],
                                      capture_output=True, text=True, timeout=90)
            (output / (name + ".compile.log")).write_text(compiled.stdout + compiled.stderr)
            assert compiled.returncode == 0, compiled.stderr
            result = subprocess.run([str(case / "fixture")], capture_output=True, text=True, timeout=20)
            text = result.stdout + result.stderr
            (output / (name + ".log")).write_text(text)
            assert (result.returncode == 0 if name == "unmodified" else
                    result.returncode != 0 and "Assertion failed:" in text), (name, text)
            receipts.append({"case": name, "exitCode": result.returncode, "assertionCaught": "Assertion failed:" in text})
    (output / "receipt.json").write_text(json.dumps({"result": "passed", "realPowerActions": 0,
        "privatePreferences": True, "sourceSHA256": hashlib.sha256(source.encode()).hexdigest(), "cases": receipts}, indent=2))
    display_probe_contracts(output, source, model)
    print("PASS: isolated production power contracts and four critical assertion-based mutants")


def display_probe_contracts(output, source, model):
    start = source.index('} else if CommandLine.arguments.contains("--verify-display") {')
    body = source[start:].split('{', 1)[1].split('} else if CommandLine.arguments.contains("--verify-real") {', 1)[0]
    body = body.replace('let power = MacPower()', 'let power = fixturePower').replace(
        'let control = Protection(power)', 'let control = fixtureControl').replace('Thread.sleep(forTimeInterval: 2)', '')
    cleanup = '''        defer {
            do { try control.shutdown() }
            catch { fputs("ERROR: display verification cleanup failed: \\(error.localizedDescription)\\n", stderr) }
        }
'''
    assert body.count(cleanup) == 1
    fixture = r'''
final class ProbePower: PowerControl {
    var value = false, idle = false, display = false, denyCleanup = false, refuseAfterFailure = false
    var calls = 0, failAt = 0
    func setBlocked(_ enabled: Bool) throws {
        if !enabled && denyCleanup { throw PowerError(message: "cleanup refused") }
        value = enabled
    }
    func blocked() throws -> Bool { value }
    func holdIdle() throws { idle = true }
    func releaseIdle() { idle = false }
    func holdDisplay() throws {
        calls += 1
        if calls == failAt { denyCleanup = refuseAfterFailure; throw PowerError(message: "display refused") }
        display = true
    }
    func releaseDisplay() { display = false }
    func displayHeld() -> Bool { display }
}
@main enum ProbeContracts {
    static func main() throws {
        for failure in [0, 1, 2, 3] {
            let fixturePower = ProbePower()
            fixturePower.failAt = failure == 3 ? 1 : failure
            fixturePower.refuseAfterFailure = failure == 3
            let fixtureControl = Protection(fixturePower)
            func probe() throws { PROBE_BODY }
            var failed = false
            do { try probe() } catch { failed = true }
            assert(failed == (failure != 0), "Probe error must remain visible")
            if failure == 3 {
                assert(fixtureControl.active && fixturePower.value, "Cleanup refusal retains retryable ownership")
                fixturePower.denyCleanup = false
                try fixtureControl.shutdown()
            }
            assert(!fixturePower.value && !fixturePower.idle && !fixturePower.display,
                   "Diagnostic display failures must release acquired system protection")
        }
        print("PASS: actual CLI branch normal/first/second assertion failure and refused-cleanup retry")
    }
}
'''
    receipts = []
    with tempfile.TemporaryDirectory(dir=output, prefix="display-probe-") as directory:
        case = Path(directory)
        (case / "Model.swift").write_text(model)
        for name, tested in [("unmodified", body), ("missing-cleanup", body.replace(cleanup, '', 1))]:
            (case / "Probe.swift").write_text('import Foundation\n' + fixture.replace('PROBE_BODY', tested))
            compiled = subprocess.run(['swiftc', '-module-cache-path', str(output / 'module-cache'),
                str(case / 'Model.swift'), str(case / 'Probe.swift'), '-o', str(case / 'fixture')],
                capture_output=True, text=True, timeout=90)
            assert compiled.returncode == 0, compiled.stderr
            result = subprocess.run([str(case / 'fixture')], capture_output=True, text=True, timeout=20)
            text = result.stdout + result.stderr
            (output / (name + '.display-probe.log')).write_text(text)
            assert (result.returncode == 0 and 'ERROR: display verification cleanup failed:' in text if name == 'unmodified'
                    else result.returncode != 0 and 'Assertion failed:' in text), (name, text)
            receipts.append({'case': name, 'exitCode': result.returncode})
    (output / 'display-probe-receipt.json').write_text(json.dumps({'result': 'passed', 'realPowerActions': 0,
        'sourceSHA256': hashlib.sha256(source.encode()).hexdigest(), 'cases': receipts}, indent=2))
    print('PASS: production diagnostic CLI branch with fake power and one missing-cleanup mutant')


def ui_mutations(output):
    source = (ROOT / "Sources/NoSleep.swift").read_text()
    faults = [
        ("power-readiness", 'if ["sleep-on", "display-on", "all-on"].contains(command), permissionReady != true {',
         "if false {", "FAIL: direct enable commands cannot bypass permission"),
        ("lock-readiness", 'if command == "all-on", !lockController.state.ready { render(); return }',
         "", "FAIL: unready combined enable starts no password or power action"),
        ("menu-readiness", "let menu = NSMenu(); menu.autoenablesItems = false", "let menu = NSMenu()",
         "FAIL: native menu validation preserves missing-permission guards"),
        ("setup-selection", 'restorePower(system: true, display: UserDefaults.standard.bool(forKey: "KeepDisplayAwake"))',
         'render(); perform("sleep-on")', "FAIL: completed setup retains saved display selection"),
    ]
    receipts = []
    with tempfile.TemporaryDirectory(dir=output, prefix="ui-mutants-") as directory:
        candidate = Path(directory)
        shutil.copytree(ROOT / "Sources", candidate / "Sources")
        (candidate / "tests").mkdir()
        shutil.copytree(ROOT / "tests/ui_harness", candidate / "tests/ui_harness")
        shutil.copy2(ROOT / "tests/ui_acceptance.py", candidate / "tests/ui_acceptance.py")
        for name, before, after, expected in [("unmodified", "", "", ""), *faults]:
            if before:
                assert source.count(before) == 1, name
            (candidate / "Sources/NoSleep.swift").write_text(source.replace(before, after, 1) if before else source)
            result = subprocess.run([sys.executable, str(candidate / "tests/ui_acceptance.py"), "--no-screenshots", "--readiness-only"],
                                    capture_output=True, text=True, timeout=150,
                                    env={**os.environ, "NOSLEEP_UI_MODULE_CACHE": str(ROOT / "build/module-cache/ui-rollback")})
            text = result.stdout + result.stderr
            (output / (name + ".ui.log")).write_text(text)
            assert (result.returncode == 0 if name == "unmodified" else result.returncode != 0 and expected in text), (name, text)
            receipts.append({"case": name, "exitCode": result.returncode, "expectedAssertion": expected})
    (output / "ui-mutations.json").write_text(json.dumps({"result": "passed", "realPowerActions": 0, "cases": receipts}, indent=2))
    print("PASS: unchanged isolated UI and four readiness/setup mutants caught by their exact assertions")


if __name__ == "__main__":
    main()
