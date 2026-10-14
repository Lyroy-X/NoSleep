"""Check the public checkout without running installers or accessing user state."""
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


def checkout_files(root):
    result = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=root, capture_output=True, check=True)
    return [root / path for path in result.stdout.decode().split("\0") if path]


def personal_paths(text):
    return re.findall(r"/Users/(?!admin(?:/|\b)|runner(?:/|\b)|Shared(?:/|\b))[\w.-]+/", text)


def broken_readme_links(root):
    links = re.findall(r"\[[^\]]+\]\(([^)]+)\)", (root / "README.md").read_text())
    return [link for link in links if "://" not in link and not link.startswith("#")
            and not (root / link.split("#", 1)[0]).is_file()]


class PublicRepositoryAcceptance(unittest.TestCase):
    def test_retired_lab_and_dependent_operators_are_absent(self):
        self.assertFalse((ROOT / "infra/vpn-lab").exists())
        for name in ("guest_operator.py", "owned_vm_probe.swift", "run_owned_vm.py"):
            self.assertFalse((ROOT / "infra/power-handoff" / name).exists())
        self.assertTrue((ROOT / "infra/power-handoff/bridge.swift").is_file())
        self.assertTrue((ROOT / "tests/power_handoff_contract.py").is_file())

    def test_current_checkout_does_not_disclose_personal_workstation_paths(self):
        found = []
        for path in checkout_files(ROOT):
            if path.is_file() and path.suffix in {".md", ".py", ".swift", ".sh", ".yaml", ".yml"}:
                if personal_paths(path.read_text()):
                    found.append(str(path.relative_to(ROOT)))
        self.assertEqual(found, [])

    def test_installation_and_update_instructions_have_valid_local_links(self):
        self.assertEqual(broken_readme_links(ROOT), [])
        readme = (ROOT / "README.md").read_text()
        for required in ("releases/latest", "NoSleep-universal.dmg", "SHA256SUMS.txt",
                         "Открыть всё равно", "Настроить NoSleep", "macOS 14+",
                         "Apple Silicon", "Intel", "Во время замены защита NoSleep снята"):
            self.assertIn(required, readme)
        for script in re.findall(r"python3 (tests/[\w.-]+\.py)", readme):
            self.assertTrue((ROOT / script).is_file(), script)

    def test_path_detector_covers_allowed_and_private_accounts(self):
        private = str(Path("/") / "Users" / "private-user" / "checkout")
        self.assertTrue(personal_paths(private))
        self.assertTrue(personal_paths(private.replace("private-user", "user.with-dots")))
        for value in ("relative/project", "/Users/admin/NoSleepLab", "/Users/runner/work", "/Users/Shared/project"):
            self.assertEqual(personal_paths(value), [])

    def test_link_checker_catches_missing_target_then_accepts_repair(self):
        with tempfile.TemporaryDirectory(prefix="nosleep-readme-contract-") as directory:
            root = Path(directory)
            (root / "README.md").write_text("[setup](setup.md#install) [release](https://example.invalid) [section](#local)")
            self.assertEqual(broken_readme_links(root), ["setup.md#install"])
            (root / "setup.md").write_text("# install")
            self.assertEqual(broken_readme_links(root), [])
            (root / "setup.md").unlink()
            self.assertEqual(broken_readme_links(root), ["setup.md#install"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
