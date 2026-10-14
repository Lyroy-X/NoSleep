"""Negative tests prove that unrelated tests, exclusions and missing evidence fail."""
import importlib.util
import json
from pathlib import Path
import unittest
import subprocess

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("quality", ROOT / "scripts/quality.py")
quality = importlib.util.module_from_spec(spec)
spec.loader.exec_module(quality)


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.paths = ["scripts/release.py", "tests/release_acceptance.py", "CHANGELOG.md", "docs/releases.md"]
        self.proof = {"behavior": "Exact-source release and safe retry", "mode": "regression",
                      "productionPaths": ["scripts/release.py"], "tests": ["tests/release_acceptance.py"]}

    def check(self, paths=None, proof=None, exists=lambda _: True):
        return quality.check_evidence(self.paths if paths is None else paths,
                                      [self.proof] if proof is None else proof, exists)

    def test_changed_file_has_exact_test_owner(self):
        self.assertEqual(set(self.check()), {"scripts/release.py"})
        for path in ["Sources/NoSleep.swift", ".github/workflows/release.yml"]:
            declaration = {**self.proof, "productionPaths": [path]}
            self.assertIn(path, self.check([path, *self.paths[1:]], [declaration]))
        self.assertFalse(quality.production_path("Sources/FeatureTests.swift"))
        self.assertFalse(quality.production_path("README.md"))
        self.assertTrue(quality.test_path("Sources/FeatureTests.swift"))
        self.assertFalse(quality.test_path("scripts/release.py"))
        self.assertEqual(quality.check_evidence(["README.md"], [], lambda _: True), {})

    def test_missing_duplicate_or_extra_ownership_is_rejected(self):
        cases = [[], [self.proof, self.proof], [{**self.proof, "productionPaths": ["scripts/unchanged.py"]}]]
        for proof in cases:
            with self.subTest(proof=proof), self.assertRaises(quality.QualityError):
                self.check(proof=proof)

    def test_unrelated_missing_deleted_or_unchanged_test_is_rejected(self):
        for test in ["README.md", "scripts/release.py", "tests/unchanged.py"]:
            with self.subTest(test=test), self.assertRaises(quality.QualityError):
                self.check(proof=[{**self.proof, "tests": [test]}])
        with self.assertRaises(quality.QualityError):
            self.check(exists=lambda _: False)

    def test_paths_cannot_escape_or_disguise_the_evidence(self):
        for path in [None, "", "/tmp/test.py", "tests/../scripts/evil.py", "tests//test.py", "tests\\test.py", "tests/a\nb.py", "./tests/test.py"]:
            with self.subTest(path=path), self.assertRaises(quality.QualityError):
                quality.safe_path(path)
        self.assertEqual(quality.safe_path("tests/a.py"), "tests/a.py")

    def test_malformed_empty_and_duplicate_lists_fail(self):
        for field, value in [("behavior", ""), ("mode", "skip"), ("productionPaths", []),
                             ("productionPaths", [None]), ("productionPaths", ["scripts/release.py"] * 2),
                             ("tests", []), ("tests", "tests/foo.py"), ("tests", ["tests/release_acceptance.py"] * 2)]:
            with self.subTest(field=field, value=value), self.assertRaises(quality.QualityError):
                self.check(proof=[{**self.proof, field: value}])
        with self.assertRaises(quality.QualityError):
            self.check(proof=[{**self.proof, "command": "arbitrary shell"}])
        for malformed in [None, [], "text"]:
            with self.subTest(malformed=malformed), self.assertRaises(quality.QualityError):
                self.check(proof=[malformed])
        for missing in ["CHANGELOG.md", "docs/releases.md"]:
            with self.subTest(missing=missing), self.assertRaises(quality.QualityError):
                self.check(paths=[path for path in self.paths if path != missing])

    def test_evidence_json_is_an_array(self):
        self.assertEqual(quality.load_evidence(json.dumps([self.proof])), [self.proof])
        with self.assertRaises(quality.QualityError):
            quality.load_evidence('{}')

    def test_red_green_requires_behavior_failure_not_import_failure(self):
        python = subprocess.CompletedProcess([], 1, "", "FAIL: test_behavior\nFAILED (failures=1)")
        self.assertIn("test_behavior", quality.meaningful_regression(python, True))
        swift = subprocess.CompletedProcess([], 1, "", "ERROR: guard retained the wrong state")
        self.assertIn("guard", quality.meaningful_regression(swift, False))
        for result, is_python in [(subprocess.CompletedProcess([], 0, "", ""), True),
                                  (subprocess.CompletedProcess([], 0, "", "FAIL: fake failure"), True),
                                  (subprocess.CompletedProcess([], 1, "", "ERROR: ModuleNotFoundError"), True),
                                  (subprocess.CompletedProcess([], 1, "", "compiler failed"), False)]:
            with self.subTest(result=result), self.assertRaises(quality.QualityError):
                quality.meaningful_regression(result, is_python)

    def test_changelog_requires_exact_nonplaceholder_version_notes(self):
        self.assertEqual(quality.check_changelog("# Changes\n## [3.4.1]\nA real fix\n## [3.4.0]\nPrevious", "3.4.1"), "A real fix")
        self.assertEqual(quality.check_changelog("## [3.4.1]\nA real fix", "3.4.1"), "A real fix")
        for content in ["## [3.4.0]\nold", "## [3.4.1]\n", "## [3.4.1]\nTODO", "## [3.4.1]\nfix\n## [3.4.1]\nduplicate"]:
            with self.subTest(content=content), self.assertRaises(quality.QualityError):
                quality.check_changelog(content, "3.4.1")


class CoverageTests(unittest.TestCase):
    def report(self, **changes):
        entry = {"executed_lines": [1, 2], "missing_lines": [], "excluded_lines": [], "missing_branches": []}
        entry.update(changes)
        return {"files": {"scripts/release.py": entry}}

    def test_all_changed_executable_lines_and_branches_are_required(self):
        self.assertEqual(quality.check_coverage({"scripts/release.py": {1, 2, 3}}, self.report()), {"scripts/release.py": 2})
        for changes in [{"executed_lines": [1], "missing_lines": [2]}, {"missing_branches": [[2, 7]]}, {"excluded_lines": [2]}]:
            with self.subTest(changes=changes), self.assertRaises(quality.QualityError):
                quality.check_coverage({"scripts/release.py": {2}}, self.report(**changes))
        self.assertEqual(quality.check_coverage({"scripts/release.py": {1}}, self.report(missing_lines=[2], missing_branches=[[2, 7]])), {"scripts/release.py": 1})

    def test_missing_source_and_missing_branch_measurements_fail(self):
        for report in [{}, {"files": {}}, {"files": {"scripts/release.py": []}}, {"files": {"scripts/release.py": {"executed_lines": [1], "missing_lines": []}}}]:
            with self.subTest(report=report), self.assertRaises(quality.QualityError):
                quality.check_coverage({"scripts/release.py": {1}}, report)
        self.assertEqual(quality.check_coverage({"README.md": {1}, "scripts/test.sh": {1}, "scripts/check-quality.py": {1}, "scripts/quality.py": set()}, {"files": {}}), {})

    def test_zero_context_diff_handles_additions_deletions_and_payload_headers(self):
        diff = "diff --git a/scripts/a.py b/scripts/a.py\n+++ b/scripts/a.py\n@@ -1,2 +1,3 @@\n+x\n+text\n+z\ndiff --git a/scripts/b.py b/scripts/b.py\n+++ b/scripts/b.py\n@@ -4 +4 @@\n+y\n@@ -8,1 +8,0 @@\n-old\n"
        self.assertEqual(quality.changed_lines(diff), {"scripts/a.py": {1, 2, 3}, "scripts/b.py": {4}})
        for bad in ["@@ -0,0 +1 @@\n+x", "+++ b/scripts/a.py\n@@ broken @@"]:
            with self.subTest(bad=bad), self.assertRaises(quality.QualityError):
                quality.changed_lines(bad)
        payload = "diff --git a/scripts/a.py b/scripts/a.py\n+++ b/scripts/a.py\n@@ -1 +1 @@\n+++ b/scripts/fake.py\n@@ -8 +8 @@\n+new\n"
        self.assertEqual(quality.changed_lines(payload), {"scripts/a.py": {1, 8}})
        deleted = "diff --git a/scripts/removed.py b/scripts/removed.py\n+++ /dev/null\n@@ -1,3 +0,0 @@\n-old\n"
        self.assertEqual(quality.changed_lines(deleted), {})
        with self.assertRaises(quality.QualityError):
            quality.changed_lines(deleted.replace("+0,0", "+1,1"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
