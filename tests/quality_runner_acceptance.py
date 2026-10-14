"""Real disposable red-green fixtures prove that the CI runner transplants tests."""
import importlib.util
import io
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
spec = importlib.util.spec_from_file_location("quality_runner", ROOT / "scripts/check-quality.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="quality-runner-fixture-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        (self.root / "tests").mkdir()
        (self.root / "scripts").mkdir()
        (self.root / "scripts/policy.txt").write_text("fixed")
        self.test = ('import unittest\nfrom pathlib import Path\n'
                     'class Contract(unittest.TestCase):\n'
                     ' def test_policy(self):\n'
                     '  self.assertEqual((Path(__file__).resolve().parents[1]/"scripts/policy.txt").read_text(), "fixed")\n'
                     'unittest.main()\n')
        (self.root / "tests/focused.py").write_text(self.test)
        self.proof = {"behavior": "Wrong old policy is fixed", "mode": "regression",
                      "productionPaths": ["scripts/policy.txt"], "tests": ["tests/focused.py"]}
        self.archive = self.base_archive()

    def base_archive(self, value="old", symlink=False):
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode="w") as archive:
            for name, content in {"scripts/policy.txt": value, "tests/focused.py": "raise RuntimeError('old test must be replaced')\n"}.items():
                entry = tarfile.TarInfo(name)
                payload = content.encode()
                entry.size = len(payload)
                if symlink and name == "tests/focused.py":
                    entry.type = tarfile.SYMTYPE
                    entry.linkname = "../scripts/policy.txt"
                    entry.size = 0
                    archive.addfile(entry)
                else:
                    archive.addfile(entry, io.BytesIO(payload))
        return stream.getvalue()

    def prove(self, proof=None, archive=None):
        output = self.root / "receipt"
        output.mkdir(exist_ok=True)
        with patch.object(runner, "ROOT", self.root), patch.object(runner.subprocess, "check_output", return_value=self.archive if archive is None else archive):
            runner.regression_proofs([self.proof if proof is None else proof], "a" * 40, output)
        return output

    def test_green_current_test_is_transplanted_and_red_on_old_behavior(self):
        green = subprocess.run([sys.executable, str(self.root / "tests/focused.py")], capture_output=True)
        self.assertEqual(green.returncode, 0)
        output = self.prove()
        self.assertIn("FAIL: test_policy", (output / "red-green-0.log").read_text())
        self.assertEqual((self.root / "scripts/policy.txt").read_text(), "fixed")

    def test_test_that_already_passes_on_base_is_rejected(self):
        with self.assertRaises(runner.quality.QualityError):
            self.prove(archive=self.base_archive("fixed"))

    def test_missing_import_is_not_a_behavior_proof(self):
        (self.root / "tests/focused.py").write_text("import absent_test_fixture\n")
        with self.assertRaises(runner.quality.QualityError):
            self.prove()

    def test_base_symlink_cannot_redirect_test_materialization(self):
        with self.assertRaises(runner.quality.QualityError):
            self.prove(archive=self.base_archive(symlink=True))

    def test_preservation_does_not_claim_red_green(self):
        output = self.prove({**self.proof, "mode": "preservation"})
        self.assertEqual(list(output.iterdir()), [])


    def test_native_proof_is_deferred_on_linux_before_any_build(self):
        proof = {**self.proof, "tests": ["Sources/UITests.swift"]}
        output = self.root / "deferred"; output.mkdir()
        with patch.object(runner.sys, "platform", "linux"), patch.object(runner.subprocess, "check_output", side_effect=AssertionError("Native build requested on an unsupported lane")) as archive:
            runner.regression_proofs([proof], "a" * 40, output)
        archive.assert_not_called()
        self.assertIn("DEFERRED", (output / "red-green-0.log").read_text())

    def test_native_only_does_not_repeat_python_proofs(self):
        output = self.root / "native-only"; output.mkdir()
        with patch.object(runner.subprocess, "check_output", side_effect=AssertionError("Native build requested on an unsupported lane")) as archive:
            runner.regression_proofs([self.proof], "a" * 40, output, native_only=True)
        archive.assert_not_called()
        self.assertEqual(list(output.iterdir()), [])

    def test_native_proof_runs_build_and_observes_behavior_error_on_macos(self):
        (self.root / "Sources").mkdir()
        (self.root / "Sources/UITests.swift").write_text("// transplanted focused native test")
        proof = {**self.proof, "tests": ["Sources/UITests.swift"]}
        output = self.root / "native-proof"; output.mkdir()
        with patch.object(runner, "ROOT", self.root), patch.object(runner.sys, "platform", "darwin"), \
                patch.object(runner.subprocess, "check_output", return_value=self.archive), \
                patch.object(runner, "run") as build, \
                patch.object(runner.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "", "ERROR: old incorrect behavior")):
            runner.regression_proofs([proof], "a" * 40, output, native_only=True)
        self.assertEqual(build.call_count, 1)
        self.assertIn("ERROR: old incorrect behavior", (output / "red-green-0.log").read_text())

if __name__ == "__main__":
    unittest.main(verbosity=2)
