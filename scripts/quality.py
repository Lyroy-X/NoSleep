"""Fail-closed diff/test ownership and changed Python coverage policy."""
import json
from pathlib import PurePosixPath
import re


class QualityError(RuntimeError):
    pass


def production_path(path):
    return (path.startswith(("Sources/", "scripts/", ".github/workflows/"))
            and not path.endswith("Tests.swift") and not path.endswith("UITests.swift"))


def test_path(path):
    return ((path.startswith("tests/") and path.endswith((".py", ".swift")))
            or (path.startswith("Sources/") and path.endswith("Tests.swift")))


def safe_path(path):
    if (not isinstance(path, str) or not path or "\\" in path or "\n" in path
            or PurePosixPath(path).is_absolute() or ".." in PurePosixPath(path).parts
            or str(PurePosixPath(path)) != path):
        raise QualityError("Evidence paths must be normalized relative regular-file paths")
    return path


def check_evidence(changed, declarations, exists):
    expected = {path for path in changed if production_path(path)}
    owners = {}
    for declaration in declarations:
        if (not isinstance(declaration, dict)
                or set(declaration) != {"behavior", "mode", "productionPaths", "tests"}
                or not isinstance(declaration["behavior"], str) or not declaration["behavior"].strip()
                or declaration["mode"] not in ("new-capability", "regression", "preservation")):
            raise QualityError("Evidence needs behavior, mode, productionPaths and tests")
        paths = declaration["productionPaths"]
        tests = declaration["tests"]
        if (not isinstance(paths, list) or not paths or not isinstance(tests, list) or not tests
                or any(not isinstance(item, str) for item in paths + tests)
                or len(set(paths)) != len(paths) or len(set(tests)) != len(tests)):
            raise QualityError("Evidence requires nonempty unique production and test paths")
        for path in paths:
            safe_path(path)
            if path in owners or path not in expected:
                raise QualityError("Evidence has duplicate ownership or an unchanged production path")
            owners[path] = declaration
        for path in tests:
            safe_path(path)
            if not test_path(path) or path not in changed or not exists(path):
                raise QualityError("Evidence must name changed, existing focused test files")
    if set(owners) != expected:
        raise QualityError("Missing exact test ownership: " + ", ".join(sorted(expected - set(owners))))
    if expected and not any(path == "CHANGELOG.md" for path in changed):
        raise QualityError("Production changes require CHANGELOG.md")
    if expected and not any(path in ("README.md", "AGENTS.md") or path.startswith("docs/") for path in changed):
        raise QualityError("Production changes require updated project documentation")
    return owners


def changed_lines(diff):
    """Parse zero-context Git hunks without matching payload text as filenames."""
    result = {}
    current = None
    in_hunk = False
    deleted = False
    for line in diff.splitlines():
        if line.startswith("diff --git "):
            current = None
            in_hunk = False
            deleted = False
        elif line == "+++ /dev/null" and not in_hunk:
            deleted = True
        elif line.startswith("+++ b/") and not in_hunk:
            current = safe_path(line[6:])
            result.setdefault(current, set())
        elif line.startswith("@@ "):
            match = re.match(r"@@ -[0-9]+(?:,[0-9]+)? \+([0-9]+)(?:,([0-9]+))? @@", line)
            if match is None:
                raise QualityError("Cannot parse changed executable line ranges")
            start, count = int(match.group(1)), int(match.group(2) or 1)
            if deleted:
                if count != 0:
                    raise QualityError("Deleted file cannot have executable additions")
                continue
            if current is None:
                raise QualityError("Missing changed source path")
            in_hunk = True
            result[current].update(range(start, start + count))
    return result


# CI orchestration is tested as a black-box contract with critical mutations.
BLACK_BOX_PYTHON = {"scripts/check-quality.py", "scripts/check-mutations.py"}


def check_coverage(lines, report):
    files = report.get("files")
    if not isinstance(files, dict):
        raise QualityError("Coverage report has no file measurements")
    verified = {}
    for path, additions in lines.items():
        if not production_path(path) or not path.endswith(".py") or path in BLACK_BOX_PYTHON or not additions:
            continue
        measurement = files.get(path)
        if not isinstance(measurement, dict):
            raise QualityError("Changed Python source is absent from coverage: " + path)
        if "missing_branches" not in measurement:
            raise QualityError("Branch coverage must be enabled")
        executable = set(measurement["executed_lines"]) | set(measurement["missing_lines"])
        excluded = set(measurement.get("excluded_lines", [])) & additions
        missing = set(measurement["missing_lines"]) & additions
        branches = [pair for pair in measurement.get("missing_branches", []) if pair[0] in additions]
        if excluded or missing or branches:
            raise QualityError(f"Uncovered or excluded changed code in {path}: lines={sorted(missing | excluded)}, branches={branches}")
        verified[path] = len(executable & additions)
    return verified


def check_changelog(content, version):
    heading = "## [" + version + "]"
    sections = content.splitlines()
    positions = [i for i, line in enumerate(sections) if line == heading]
    if len(positions) != 1:
        raise QualityError("Changelog needs exactly one heading for the release version")
    end = next((i for i in range(positions[0] + 1, len(sections)) if sections[i].startswith("## [")), len(sections))
    notes = "\n".join(sections[positions[0] + 1:end]).strip()
    if not notes or re.search(r"\b(TODO|TBD|placeholder)\b", notes, re.IGNORECASE):
        raise QualityError("Release notes must describe real changes")
    return notes


def load_evidence(content):
    declarations = json.loads(content)
    if not isinstance(declarations, list):
        raise QualityError("Evidence file must contain an array")
    return declarations


def meaningful_regression(result, python):
    """An import/compile failure cannot prove that an old behavior was wrong."""
    output = result.stdout + result.stderr
    if result.returncode == 0:
        raise QualityError("Regression test did not fail on the base revision")
    if python:
        if re.search(r"^FAIL: [A-Za-z_]", output, re.MULTILINE) is None or re.search(r"^ERROR: [A-Za-z_]", output, re.MULTILINE):
            raise QualityError("Base test failed for setup/import reasons, not a behavior assertion")
    elif "ERROR:" not in output:
        raise QualityError("Base Swift self-test did not produce a behavioral failure")
    return output
