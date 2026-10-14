"""Check the publishing trust boundary and required CI lanes structurally."""
from pathlib import Path
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.release = yaml.safe_load((ROOT / ".github/workflows/release.yml").read_text())
        self.ci = yaml.safe_load((ROOT / ".github/workflows/regression.yml").read_text())

    def test_only_main_push_can_publish_with_write_permission(self):
        self.assertEqual(self.release["on"], {"push": {"branches": ["main"]}})
        self.assertEqual(self.release["permissions"], {"contents": "read"})
        self.assertEqual(self.ci["permissions"], {"contents": "read"})
        self.assertEqual(self.release["jobs"]["publish"]["permissions"], {"contents": "write"})
        self.assertEqual(self.release["jobs"]["publish"]["needs"], "verify")
        self.assertEqual(self.release["jobs"]["verify"]["uses"], "./.github/workflows/regression.yml")

    def test_ci_runs_native_both_architectures_and_package_after_quality(self):
        self.assertEqual(self.ci["jobs"]["native-regression"]["strategy"]["matrix"]["runner"], ["macos-15", "macos-15-intel"])
        self.assertEqual(set(self.ci["jobs"]["package"]["needs"]), {"quality", "native-regression"})
        self.assertIn("pull_request", self.ci["on"])
        self.assertEqual(self.ci["on"]["push"]["branches-ignore"], ["main"])
        self.assertIn("--local", "\n".join(step.get("run", "") for step in self.ci["jobs"]["native-regression"]["steps"]))

    def test_actions_are_pinned_checkouts_do_not_persist_credentials(self):
        for workflow in (self.ci, self.release):
            for job in workflow["jobs"].values():
                for step in job.get("steps", []):
                    if "uses" not in step:
                        continue
                    self.assertRegex(step["uses"], r"^actions/[a-z-]+@[0-9a-f]{40}$")
                    if step["uses"].startswith("actions/checkout@"):
                        self.assertIs(step["with"]["persist-credentials"], False)
                        self.assertEqual(step["with"]["ref"], "${{ github.sha }}")
                    if step["uses"].startswith("actions/setup-python@"):
                        self.assertEqual(step["with"]["python-version-file"], ".python-version")
        self.assertEqual((ROOT / ".python-version").read_text().strip(), "3.12")
        self.assertEqual(self.release["concurrency"], {"group": "nosleep-release-main", "cancel-in-progress": False, "queue": "max"})

    def test_build_and_publish_use_exact_artifact_and_restricted_token(self):
        for job_name, job in self.release["jobs"].items():
            for step in job.get("steps", []):
                if step.get("env", {}).get("GH_TOKEN"):
                    self.assertEqual(job_name, "publish")
        upload = next(step for step in self.ci["jobs"]["package"]["steps"] if step.get("uses", "").startswith("actions/upload-artifact@"))
        download = next(step for step in self.release["jobs"]["publish"]["steps"] if step.get("uses", "").startswith("actions/download-artifact@"))
        self.assertEqual(upload["with"]["name"], download["with"]["name"])
        self.assertIn("github.sha", upload["with"]["name"])
        self.assertEqual(upload["with"]["if-no-files-found"], "error")


if __name__ == "__main__":
    unittest.main(verbosity=2)
