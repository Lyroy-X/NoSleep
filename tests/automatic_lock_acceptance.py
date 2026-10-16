#!/usr/bin/env python3
"""Native lock contracts and assertion-based safety mutants; fake policy only."""
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    if platform.system() != "Darwin":
        print("DEFERRED: native automatic-lock contracts require the macOS regression lane")
        return
    output = ROOT / "build/automatic-lock-acceptance"
    output.mkdir(parents=True, exist_ok=True)
    source = (ROOT / "Sources/AutomaticLock.swift").read_text()
    tests = (ROOT / "Sources/AutomaticLockTests.swift").read_text()
    mutants = [
        ("journal-before-policy", "try store.save(original); restore = original", "restore = original"),
        ("console-session", "guard consoleSession() else { throw ScreenLockFailure.unavailable }", "// removed session guard"),
        ("external-change", "guard try backend.read() == plan.expected else { throw ScreenLockFailure.changed }", "// removed change guard"),
        ("error-checkbox", "state.enabled = wasEnabled; state.issue", "state.enabled = plan.enabled; state.issue"),
        ("journal-symlink", "O_RDONLY | O_NOFOLLOW", "O_RDONLY"),
    ]
    receipts = []
    with tempfile.TemporaryDirectory(dir=output, prefix="isolated-") as directory:
        case = Path(directory)
        (case / "Tests.swift").write_text(tests)
        (case / "Main.swift").write_text('import Foundation\n@main enum Main { static func main() { do { try automaticLockTests() } catch { fputs(error.localizedDescription + "\\n", stderr); exit(1) } } }\n')
        for name, old, replacement in [("unmodified", "", ""), *mutants]:
            if old:
                assert old in source, name
            changed = source.replace(old, replacement) if old else source
            (case / "Policy.swift").write_text(changed)
            compile_result = subprocess.run([
                "swiftc", "-target", platform.machine() + "-apple-macos14.0", "-module-cache-path", str(output / "module-cache"),
                str(case / "Policy.swift"), str(case / "Tests.swift"), str(case / "Main.swift"), "-o", str(case / "fixture"),
            ], capture_output=True, text=True, timeout=90)
            (output / (name + "-compile.log")).write_text(compile_result.stdout + compile_result.stderr)
            assert compile_result.returncode == 0, compile_result.stderr
            result = subprocess.run([str(case / "fixture")], capture_output=True, text=True, timeout=20)
            text = result.stdout + result.stderr
            (output / (name + ".log")).write_text(text)
            if name == "unmodified":
                assert result.returncode == 0, text
            else:
                assert result.returncode != 0 and "Assertion failed:" in text, (name, result.returncode, text)
            receipts.append({"case": name, "compiled": True, "exitCode": result.returncode,
                             "assertionCaught": "Assertion failed:" in text})
    receipt = {"result": "passed", "realPolicyActions": 0, "passwordStored": False,
               "sourceSHA256": hashlib.sha256(source.encode()).hexdigest(),
               "testsSHA256": hashlib.sha256(tests.encode()).hexdigest(), "cases": receipts}
    (output / "receipt.json").write_text(json.dumps(receipt, indent=2))
    print("PASS: native automatic-lock normal/error/boundary/retry contracts and five critical safety mutants")


if __name__ == "__main__":
    main()
