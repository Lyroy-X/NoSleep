#!/usr/bin/env python3
"""Prove the status confirmation boundary catches an isolated native fault."""
import json
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
output = root / "build/compact-mutation"
output.mkdir(parents=True, exist_ok=True)
source = (root / "Sources/PowerPresentation.swift").read_text()
needle = "if hasError || (systemWanted && !systemActual) || (displayWanted && (!displayActual || !systemWanted || !systemActual)) {"
assert source.count(needle) == 1
with tempfile.TemporaryDirectory(prefix="nosleep-status-mutation-") as folder:
    private = Path(folder)
    entry = private / "Entry.swift"
    entry.write_text("import Foundation\n@main enum StatusCheck { static func main() throws { try presentationTests() } }\n")
    for name, candidate in [("original", source), ("faulty", source.replace(needle, "if hasError || (displayWanted && (!displayActual || !systemWanted || !systemActual)) {"))]:
        fixture = private / "PowerPresentation.swift"
        fixture.write_text(candidate)
        binary = private / name
        compile_result = subprocess.run(["swiftc", "-module-cache-path", str(output / "module-cache"), str(fixture),
                                         str(root / "Sources/PresentationTests.swift"), str(entry), "-o", str(binary)],
                                        capture_output=True, text=True, timeout=90)
        (output / f"{name}-compile.log").write_text(compile_result.stdout + compile_result.stderr)
        assert compile_result.returncode == 0, compile_result.stderr
        result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=15)
        text = result.stdout + result.stderr
        (output / f"{name}.log").write_text(text)
        if name == "original":
            assert result.returncode == 0, text
        else:
            assert result.returncode != 0 and "Assertion failed" in text and "Requested sleep is not confirmed success" in text, text
(output / "receipt.json").write_text(json.dumps({"result": "passed", "original": "passed",
    "faulty": "assertion-failed", "boundary": "requested sleep without actual confirmation", "workingSourcesModified": False}, indent=2))
print("PASS: original native status fixture passes; missing sleep-confirmation check is killed by assertion")
