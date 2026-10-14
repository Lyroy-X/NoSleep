#!/usr/bin/env python3
"""Verify portable fixture identity guards without activating an application."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import shutil
import subprocess
import uuid


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=Path("build/ui-runner-acceptance"))
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    output = (repo / args.output).resolve()
    if not output.is_relative_to(repo / "build") or any(part.endswith(".app") for part in output.parts):
        parser.error("Output must be a dedicated directory inside repository build/")
    source = args.package.resolve()
    run = output / ("run-" + uuid.uuid4().hex)
    run.mkdir(parents=True, mode=0o700)
    cases = {
        "normal-entrypoint": lambda value: value.update(normalAppEntrypointExcluded=False),
        "foreign-bundle": lambda value: value.update(bundle="local.robert.keepawake"),
        "missing-side-effect-audit": lambda value: value.update(forbiddenRuntimeImportsAbsent=False),
        "changed-ui-executable": lambda value: value.update(fixtureExecutableHash="0" * 64),
        "changed-portable-runner": lambda value: value.update(runnerExecutableHash="0" * 64),
        "changed-info": lambda value: value.update(fixtureInfoHash="0" * 64),
    }
    checks = []
    command = [str(source / "NoSleepUIPreview.app/Contents/MacOS/ui-harness"), "--guest-cmd-v", "--guest-mac", "00:00:00:00:00:00"]
    refused = subprocess.run(command, text=True, capture_output=True, timeout=10)
    if refused.returncode != 1 or "Guest-only clipboard guard refused:" not in refused.stderr:
        raise RuntimeError("Unowned guest clipboard mode was not denied before AppKit")
    checks.append("unowned-guest-clipboard-before-appkit")
    denied_output = run / "denied-guest-mode"
    refused = subprocess.run([str(source / "ui-acceptance-runner"), "--guest-cmd-v", "--guest-mac", "00:00:00:00:00:00", "--output", str(denied_output)],
                             text=True, capture_output=True, timeout=10)
    denied_receipts = list(denied_output.glob("run-*/receipt.json"))
    if refused.returncode != 1 or len(denied_receipts) != 1 or list(denied_output.glob("run-*/process.json")) or list(denied_output.glob("run-*/runtime.log")):
        raise RuntimeError("Unowned guest clipboard mode was not denied before launching a fixture")
    checks.append("unowned-guest-clipboard-before-launch")
    for flag in ("--forbidden-power-action", "--forbidden-diagnostics-action"):
        process = subprocess.run([str(source / "NoSleepUIPreview.app/Contents/MacOS/ui-harness"), flag],
                                 text=True, capture_output=True, timeout=10)
        if process.returncode != 1 or "UI harness forbids:" not in process.stderr:
            raise RuntimeError(f"Fixture operation was not denied without opt-in: {flag}")
        checks.append(flag)
    for name, change in cases.items():
        package = run / name
        shutil.copytree(source, package)
        manifest_path = package / "fixture-manifest.json"
        manifest = json.loads(manifest_path.read_text())
        change(manifest)
        manifest_path.write_text(json.dumps(manifest))
        results = package / "results"
        process = subprocess.run([str(package / "ui-acceptance-runner"), "--presentation-only", "--output", str(results)],
                                 text=True, capture_output=True, timeout=10)
        (package / "guard.log").write_text(process.stdout + process.stderr)
        # A guard failure must happen before creating a run or launching even pure UI.
        if process.returncode != 1 or results.exists() or "FAIL:" not in process.stderr:
            raise RuntimeError(f"Identity guard did not reject before launch: {name}")
        checks.append(name)
    receipt = {"result": "passed", "checks": checks, "scope": "portable fixture guards only; no app activation or native UI"}
    (run / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(f"PASS: {len(checks)} pre-launch fixture identity guards; receipt {run}/receipt.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
