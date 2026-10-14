"""The same deterministic quality command for local candidates, PRs and main."""
import argparse
import hashlib
import io
import json
import os
import platform
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile

import quality
import release

ROOT = Path(__file__).resolve().parents[1]
ADOPTION_BASE = "ffcd093827c158a5b95c29658dac9dca94a6ef1f"


def run(argv, root=ROOT, environment=None):
    subprocess.run(argv, cwd=root, env=environment, check=True)


def git(*args):
    return release.git(ROOT, *args).decode()


def quality_base(base):
    release.checked_sha(base)
    # Only the first rollout uses the reviewed adoption baseline. Future PRs compare
    # their complete diff against actual main, including deletions and new files.
    check = subprocess.run(["git", "-C", str(ROOT), "cat-file", "-e", f"{base}:scripts/quality.py"], capture_output=True)
    if check.returncode == 0:
        return base
    run(["git", "merge-base", "--is-ancestor", ADOPTION_BASE, "HEAD"])
    return ADOPTION_BASE


def regression_proofs(declarations, base, output, native_only=False):
    for index, declaration in enumerate(declarations):
        if declaration["mode"] != "regression":
            continue
        native = any(path.startswith("Sources/") for path in declaration["tests"])
        if native_only and not native:
            continue
        if native and sys.platform != "darwin":
            (output / f"red-green-{index}.log").write_text("DEFERRED: native proof is required in both macOS lanes\n")
            continue
        with tempfile.TemporaryDirectory(prefix="nosleep-red-green-") as directory:
            candidate = Path(directory).resolve()
            archive = subprocess.check_output(["git", "-C", str(ROOT), "archive", base])
            with tarfile.open(fileobj=io.BytesIO(archive)) as tree:
                tree.extractall(candidate, filter="data")
            for path in declaration["tests"]:
                quality.safe_path(path)
                target = candidate / path
                if (target.is_symlink() or not target.resolve().is_relative_to(candidate)
                        or any(parent.is_symlink() for parent in target.parents if parent.is_relative_to(candidate))):
                    raise quality.QualityError("Unsafe test materialization in base snapshot")
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes((ROOT / path).read_bytes())
            native = any(path.startswith("Sources/") for path in declaration["tests"])
            if native:
                run([str(candidate / "scripts/build.sh")], root=candidate)
                result = subprocess.run([str(candidate / "build/NoSleep.app/Contents/MacOS/NoSleep"), "--self-test"],
                                        capture_output=True, text=True, timeout=180)
                text = quality.meaningful_regression(result, python=False)
            else:
                text = ""
                for path in declaration["tests"]:
                    if path in {"tests/live_acceptance.py", "tests/onboarding_acceptance.py"} or not path.endswith(".py"):
                        raise quality.QualityError("Red-green proof requires isolated native tests")
                    result = subprocess.run([sys.executable, str(candidate / path)], cwd=candidate,
                                            capture_output=True, text=True, timeout=60)
                    text += quality.meaningful_regression(result, python=True)
            (output / f"red-green-{index}.log").write_text(text)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", required=True)
    parser.add_argument("--worktree", action="store_true")
    parser.add_argument("--actionlint")
    parser.add_argument("--native-regression-proofs", action="store_true")
    args = parser.parse_args()
    output = ROOT / "build/quality"
    output.mkdir(parents=True, exist_ok=True)
    try:
        base = quality_base(args.base)
        revision = [] if args.worktree else ["HEAD"]
        paths = git("diff", "--name-only", base, *revision).splitlines()
        patch_text = git("diff", "--no-ext-diff", "--unified=0", base, *revision, "--", "scripts/*.py")
        if args.worktree:
            untracked = git("ls-files", "--others", "--exclude-standard").splitlines()
            paths.extend(untracked)
            for path in untracked:
                if path.startswith("scripts/") and path.endswith(".py"):
                    length = len((ROOT / path).read_text().splitlines())
                    patch_text += f"\ndiff --git a/{path} b/{path}\n+++ b/{path}\n@@ -0,0 +1,{length} @@\n"
        paths = sorted(set(paths))
        changed_evidence = [path for path in paths if path.startswith("tests/evidence/") and path.endswith(".json") and (ROOT / path).is_file()]
        declarations = []
        for path in changed_evidence:
            declarations.extend(quality.load_evidence((ROOT / path).read_text()))
        def exists(path):
            candidate = ROOT / path
            return candidate.is_file() and not candidate.is_symlink() and candidate.resolve().is_relative_to(ROOT)
        owners = quality.check_evidence(paths, declarations, exists)
        version, _ = release.validate_source(ROOT, args.base)
        quality.check_changelog((ROOT / "CHANGELOG.md").read_text(), version)
        if args.native_regression_proofs:
            if sys.platform != "darwin":
                raise quality.QualityError("Native proofs require macOS")
            regression_proofs(declarations, base, output, native_only=True)
            print("PASS: native regression proofs on the actual comparison base")
            return 0
        if not args.actionlint:
            raise quality.QualityError("Workflow validator is required")
        # Explicit supplement for GitHub's queue property, which actionlint 1.7.12
        # predates. All other actionlint diagnostics remain blocking.
        import yaml
        workflow = yaml.safe_load((ROOT / ".github/workflows/release.yml").read_text())
        if workflow["concurrency"] != {"group": "nosleep-release-main", "cancel-in-progress": False, "queue": "max"}:
            raise quality.QualityError("Release queue must retain pending main releases")
        if any("concurrency" in job for job in workflow["jobs"].values()):
            raise quality.QualityError("Release uses one global validated queue, not job queue overrides")
        for path in sorted([*(ROOT / ".github/workflows").glob("*.yml"), *(ROOT / ".github/workflows").glob("*.yaml")]):
            flags = ["-ignore", 'unexpected key "queue" for "concurrency" section'] if path.name == "release.yml" else []
            run([args.actionlint, "-shellcheck=", *flags, str(path)])
        for folder in ("scripts", "tests"):
            run([sys.executable, "-m", "compileall", "-q", folder])
        environment = {**os.environ, "COVERAGE_FILE": str(output / ".coverage"),
                       "COVERAGE_RCFILE": str(ROOT / ".coveragerc")}
        run([sys.executable, "-m", "coverage", "erase"], environment=environment)
        selected_tests = {"tests/release_acceptance.py", "tests/quality_acceptance.py", "tests/quality_runner_acceptance.py"}
        deferred = {"tests/dmg_acceptance.py"}  # Required by the dependent package job.
        for declaration in declarations:
            if any(path.startswith("Sources/") for path in declaration["tests"]):
                continue  # These tests, including their Python support, execute in macOS lanes.
            for path in declaration["tests"]:
                if path.startswith("Sources/") or path in deferred or path == "tests/workflow_acceptance.py":
                    continue  # Required by both native-regression jobs or package.
                if path in {"tests/live_acceptance.py", "tests/onboarding_acceptance.py"} or not path.endswith(".py"):
                    raise quality.QualityError("Focused Python tests must run in isolation without manual actions")
                selected_tests.add(path)
        for test in sorted(selected_tests):
            run([sys.executable, "-m", "coverage", "run", test], environment=environment)
        run([sys.executable, "-m", "coverage", "combine", "--keep"], environment=environment)
        run([sys.executable, "-m", "coverage", "json", "-o", str(output / "coverage.json")], environment=environment)
        measured = quality.check_coverage(quality.changed_lines(patch_text), json.loads((output / "coverage.json").read_text()))
        run([sys.executable, "tests/workflow_acceptance.py"])
        run([sys.executable, "scripts/check-mutations.py"])
        regression_proofs(declarations, base, output)
        receipts = {"result": "passed", "base": base, "requestedBase": args.base,
                    "head": git("rev-parse", "HEAD").strip(), "worktree": args.worktree,
                    "python": sys.version, "platform": platform.platform(),
                    "coverageSHA256": hashlib.sha256((output / "coverage.json").read_bytes()).hexdigest(),
                    "productionPaths": sorted(owners), "changedPythonExecutableLines": measured,
                    "inputs": {path: hashlib.sha256((ROOT / path).read_bytes()).hexdigest()
                               for path in paths if exists(path)}}
        (output / "receipt.json").write_text(json.dumps(receipts, indent=2) + "\n")
        print("PASS: exact diff evidence, release metadata, workflow, changed Python coverage and critical mutations")
    except (quality.QualityError, release.ReleaseError, OSError, ValueError, KeyError, subprocess.CalledProcessError) as failure:
        print("Quality gate failed:", failure, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
