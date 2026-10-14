"""Require focused tests to catch critical faults in disposable source copies."""
import argparse
import json
import re
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MUTATIONS = [
    ("release.py", "version_tuple(version) <= version_tuple(old_version)", "False", "release_acceptance.py"),
    ("release.py", "if build <= old_build:", "if False:", "release_acceptance.py"),
    ("release.py", "target is not None and target != source_sha", "False", "release_acceptance.py"),
    ("release.py", "hashlib.sha256((directory / DMG).read_bytes()).hexdigest() != digest", "False", "release_acceptance.py"),
    ("release.py", "if release[\"draft\"] or tag_sha(api, prefix, tag) != source_sha:", "if False:", "release_acceptance.py"),
    ("quality.py", "if set(owners) != expected:", "if False:", "quality_acceptance.py"),
    ("quality.py", "path in owners or path not in expected", "False", "quality_acceptance.py"),
    ("quality.py", "not test_path(path) or path not in changed or not exists(path)", "False", "quality_acceptance.py"),
    ("quality.py", "if excluded or missing or branches:", "if False:", "quality_acceptance.py"),
    ("quality.py", "if \"missing_branches\" not in measurement:", "if False:", "quality_acceptance.py"),
    ("quality.py", "if result.returncode == 0:", "if False:", "quality_acceptance.py"),
    ("quality.py", 'if re.search(r"^FAIL: [A-Za-z_]", output, re.MULTILINE) is None or re.search(r"^ERROR: [A-Za-z_]", output, re.MULTILINE):', "if False:", "quality_acceptance.py"),
]


def run_mutations(root, output):
    receipts = []
    for filename, before, after, test in MUTATIONS:
        source = (root / "scripts" / filename).read_text()
        if source.count(before) != 1:
            raise RuntimeError("Mutation anchor changed; update the critical test: " + before)
        with tempfile.TemporaryDirectory(prefix="nosleep-mutation-") as directory:
            candidate = Path(directory)
            shutil.copytree(root / "scripts", candidate / "scripts", ignore=shutil.ignore_patterns("__pycache__"))
            shutil.copytree(root / "tests", candidate / "tests", ignore=shutil.ignore_patterns("__pycache__"))
            shutil.copytree(root / "Resources", candidate / "Resources")
            baseline = subprocess.run([sys.executable, str(candidate / "tests" / test)], capture_output=True, text=True, timeout=30)
            if baseline.returncode != 0:
                raise RuntimeError("Unmodified mutation fixture failed; cannot attribute a red result")
            (candidate / "scripts" / filename).write_text(source.replace(before, after, 1))
            result = subprocess.run([sys.executable, str(candidate / "tests" / test)], capture_output=True, text=True, timeout=30)
            text = result.stdout + result.stderr
            killed = (result.returncode != 0 and re.search(r"^FAIL: [A-Za-z_]", text, re.MULTILINE) is not None
                      and re.search(r"^ERROR: [A-Za-z_]", text, re.MULTILINE) is None)
            receipt = {"source": filename, "fault": before, "test": test, "killed": killed}
            receipts.append(receipt)
            output.mkdir(parents=True, exist_ok=True)
            (output / f"mutation-{len(receipts)}.log").write_text(text)
            if not killed:
                raise RuntimeError("Mutation survived or failed for an unrelated reason: " + before)
    (output / "receipt.json").write_text(json.dumps(receipts, indent=2) + "\n")
    print(f"PASS: {len(receipts)} critical mutations caught by assertion failures")
    return receipts


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "build/quality/mutations")
    args = parser.parse_args()
    run_mutations(ROOT, args.output)
