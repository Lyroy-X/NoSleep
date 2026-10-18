#!/usr/bin/env python3
"""Execute exact timer/engine production code with fake power and faulty copies."""
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]


def main():
    if platform.system() != "Darwin":
        print("DEFERRED: timer native contracts require macOS")
        return
    output = ROOT / "build/timed-acceptance"
    output.mkdir(parents=True, exist_ok=True)
    source = (ROOT / "Sources/NoSleep.swift").read_text()
    model = ("import Foundation\n" + source[source.index("protocol PowerControl"):source.index("func waitForPowerState")]
             + source[source.index("final class Protection"):source.index("func selfTest()")]
             + source[source.index("struct LiveState:"):source.index("func backgroundTest()")])
    timed = (ROOT / "Sources/TimedProtection.swift").read_text()
    tests = (ROOT / "Sources/TimedProtectionTests.swift").read_text()
    mutations = [
        ("unmodified", "", ""),
        ("early-expiry", "now < $0.value.deadline", "now >= $0.value.deadline"),
        ("unbounded-history", "static let limit = 5", "static let limit = 500"),
        ("corrupt-minute-refusal", "minutes <= 59", "minutes <= 999"),
        ("lost-restoration-ownership", 'catch { timedFailure = true; actionError = "Не удалось завершить таймер. Повторите восстановление в выборе времени." }',
         'catch { timedPlan = next; timedFailure = false; actionError = nil }'),
        ("skipped-relaunch-restoration", "try self.reconcileTimed(baseline, forceOff: true)", ""),
        ("unconfirmed-assertion", "if selection.system { try protection.refresh() }", ""),
        ("no-save-journal-write", "else if save == true { self.powerDefaults.removeObject(forKey: \"TimedPowerBaseline\") }",
         "else { self.powerDefaults.removeObject(forKey: \"TimedPowerBaseline\") }"),
    ]
    receipts = []
    with tempfile.TemporaryDirectory(prefix="native-", dir=output) as directory:
        case = Path(directory)
        (case / "Tests.swift").write_text(tests + '\n@main enum Run { static func main() throws { if CommandLine.arguments.count == 3 { timedPersistencePhase(CommandLine.arguments[1], suite: CommandLine.arguments[2]) } else { try timedProtectionTests() } } }\n')
        combined = timed + "\n" + model
        for name, before, after in mutations:
            if before:
                assert combined.count(before) == 1, name
            (case / "Model.swift").write_text(combined.replace(before, after, 1) if before else combined)
            compiled = subprocess.run(["swiftc", "-module-cache-path", str(output / "module-cache"),
                                       str(case / "Model.swift"), str(case / "Tests.swift"), "-o", str(case / "fixture")],
                                      capture_output=True, text=True, timeout=90)
            (output / (name + ".compile.log")).write_text(compiled.stdout + compiled.stderr)
            assert compiled.returncode == 0, compiled.stderr
            result = subprocess.run([str(case / "fixture")], capture_output=True, text=True, timeout=15)
            runtime = result.stdout + result.stderr
            (output / (name + ".log")).write_text(runtime)
            assert (result.returncode == 0 if name == "unmodified" else
                    result.returncode != 0 and "Assertion failed" in runtime), (name, runtime)
            receipts.append({"case": name, "exitCode": result.returncode})
            if name == "unmodified":
                suite = "NoSleep.DurationPersistence." + uuid.uuid4().hex
                try:
                    for phase in ["write", "read-remove", "verify-delete"]:
                        result = subprocess.run([str(case / "fixture"), phase, suite], capture_output=True, text=True, timeout=10)
                        (output / (phase + ".log")).write_text(result.stdout + result.stderr)
                        assert result.returncode == 0, result.stdout + result.stderr
                        receipts.append({"case": phase, "exitCode": result.returncode})
                finally:
                    subprocess.run([str(case / "fixture"), "cleanup", suite], check=True, capture_output=True, timeout=10)
    paths = ["Sources/NoSleep.swift", "Sources/TimedProtection.swift", "Sources/TimedProtectionTests.swift", "tests/timed_protection_acceptance.py"]
    (output / "receipt.json").write_text(json.dumps({"result": "passed", "realPowerActions": 0,
        "inputs": {path: hashlib.sha256((ROOT / path).read_bytes()).hexdigest() for path in paths}, "cases": receipts}, indent=2))
    print("PASS: exact native timed engine, separate-process history and background deadline; seven critical mutants fail by assertion")


if __name__ == "__main__":
    main()
