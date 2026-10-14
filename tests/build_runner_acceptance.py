"""Build/test tooling cannot overwrite a running application; no real app is launched."""
import hashlib
import importlib.util
import os
import plistlib
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform == "darwin", "macOS build tooling")
class BuildRunnerAcceptance(unittest.TestCase):
    def test_failed_activity_probe_refuses_before_any_build_write(self):
        with tempfile.TemporaryDirectory(prefix="nosleep-probe-failure-") as directory:
            base = Path(directory)
            app = base / "Candidate.app"
            binary = app / "Contents/MacOS/NoSleep"
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b"owned inert fixture")
            probe = base / "lsof"
            probe.write_text('#!/bin/zsh\nprint -n -- "$PROBE_OUTPUT"\nexit "$PROBE_CODE"\n')
            probe.chmod(0o700)
            qualified = base / "build.sh"
            qualified.write_text((ROOT / 'scripts/build.sh').read_text().replace('/usr/sbin/lsof', str(probe)))
            for code, output, expected in [(2, '', 'Cannot verify'), (1, 'probe warning', 'Cannot verify'),
                                           (1, '123', 'Cannot verify'), (0, '', 'NoSleep is running'),
                                           (1, '', 'no ad-hoc fallback')]:
                with self.subTest(code=code, output=output):
                    result = subprocess.run(['/bin/zsh', str(qualified)], capture_output=True, text=True,
                        env={**os.environ, 'NOSLEEP_BUILD_APP': str(app), 'PROBE_CODE': str(code),
                             'PROBE_OUTPUT': output, 'NOSLEEP_SIGNING_CONFIG': str(base / 'missing.json')}, timeout=5)
                    self.assertEqual(result.returncode, 1)
                    self.assertIn(expected, result.stderr)
                    self.assertEqual(binary.read_bytes(), b'owned inert fixture')
                    self.assertFalse((app / 'Contents/Info.plist').exists())

    def test_failed_signer_activity_probe_refuses_before_keychain_access(self):
        spec = importlib.util.spec_from_file_location('signer_probe_contract', ROOT / 'scripts/sign-local-development.py')
        signer = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(signer)
        with tempfile.TemporaryDirectory(prefix='nosleep-signer-probe-') as directory:
            app = Path(directory) / 'Candidate.app'
            binary = app / 'Contents/MacOS/NoSleep'
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b'owned inert fixture')
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'local.robert.keepawake',
                                                                  'CFBundleExecutable': 'NoSleep'}))
            for code, stdout, stderr in [(2, '', ''), (1, '', 'warning'), (1, '123', ''), (0, '', '')]:
                with self.subTest(code=code, stdout=stdout, stderr=stderr), \
                     patch.object(signer.subprocess, 'run', return_value=subprocess.CompletedProcess([], code, stdout, stderr)), \
                     patch.object(signer, 'certificate_present') as certificate, \
                     patch.object(signer, 'keychain_password') as secret:
                    with self.assertRaises(signer.SigningError):
                        signer.sign(app, {'identity': 'a' * 40})
                    certificate.assert_not_called()
                    secret.assert_not_called()
                    self.assertEqual(binary.read_bytes(), b'owned inert fixture')

    def test_signer_cli_refuses_before_ensure_can_access_keychain(self):
        spec = importlib.util.spec_from_file_location('signer_cli_probe_contract', ROOT / 'scripts/sign-local-development.py')
        signer = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(signer)
        with patch.object(sys, 'argv', ['sign-local-development.py', 'sign', '/owned/Candidate.app']), \
             patch.object(signer, 'signing_preflight', side_effect=signer.SigningError('uncertain activity')) as preflight, \
             patch.object(signer, 'ensure') as ensure, patch.object(signer, 'sign') as sign:
            self.assertEqual(signer.main(), 1)
            preflight.assert_called_once_with(Path('/owned/Candidate.app'))
            ensure.assert_not_called()
            sign.assert_not_called()

    def test_explicit_missing_identity_cannot_silently_build_ad_hoc(self):
        with tempfile.TemporaryDirectory(prefix="nosleep-signing-guard-") as directory:
            app = Path(directory) / "Candidate.app"
            attempt = subprocess.run([str(ROOT / "scripts/build.sh")], capture_output=True, text=True,
                env={**os.environ, "NOSLEEP_BUILD_APP": str(app),
                     "NOSLEEP_SIGNING_CONFIG": str(Path(directory) / "missing-identity.json")}, timeout=5)
            self.assertEqual(1, attempt.returncode)
            self.assertIn("no ad-hoc fallback", attempt.stderr)
            self.assertFalse(app.exists(), "Invalid explicit signing identity wrote an application")

    def test_unknown_test_mode_is_rejected_before_building(self):
        process = subprocess.run([str(ROOT / "scripts/test.sh"), "--unknown"],
                                 capture_output=True, text=True, timeout=5)
        self.assertEqual(process.returncode, 2)
        self.assertIn("Usage:", process.stderr)

    def test_running_fixture_executable_is_not_overwritten(self):
        # The fixture only sleeps. It has no AppKit, power, Cisco or Keychain access.
        with tempfile.TemporaryDirectory(prefix="nosleep-build-guard-") as directory:
            root = Path(directory)
            source = root / "fixture.swift"
            source.write_text("import Darwin\nsleep(30)\n")
            app = root / "Fixture.app"
            executable = app / "Contents/MacOS/NoSleep"
            executable.parent.mkdir(parents=True)
            subprocess.run(["swiftc", "-module-cache-path", str(ROOT / "build/module-cache/build-guard"),
                            str(source), "-o", str(executable)], check=True, timeout=45)
            before = hashlib.sha256(executable.read_bytes()).hexdigest()
            owned = subprocess.Popen([str(executable)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                deadline = time.monotonic() + 5
                while str(executable) not in subprocess.check_output(["/bin/ps", "-axo", "comm="], text=True).splitlines():
                    self.assertLess(time.monotonic(), deadline, "Fixture did not appear in the process table")
                    time.sleep(.05)
                attempt = subprocess.run([str(ROOT / "scripts/build.sh")], capture_output=True, text=True,
                                         env={**os.environ, "NOSLEEP_BUILD_APP": str(app)}, timeout=10)
                self.assertEqual(attempt.returncode, 1)
                self.assertIn("NoSleep is running", attempt.stderr)
                self.assertEqual(hashlib.sha256(executable.read_bytes()).hexdigest(), before)
                self.assertFalse((app / "Contents/Info.plist").exists(), "Build wrote resources despite guard")
                package_attempt = subprocess.run([str(ROOT / "scripts/package-dmg.sh")], capture_output=True, text=True,
                                                 env={**os.environ, "NOSLEEP_BUILD_APP": str(app)}, timeout=10)
                self.assertEqual(package_attempt.returncode, 1)
                self.assertIn("NoSleep is running", package_attempt.stderr)
                self.assertEqual(hashlib.sha256(executable.read_bytes()).hexdigest(), before)
                self.assertFalse((app / "Contents/Info.plist").exists(), "Packaging wrote into a running application")
            finally:
                if owned.poll() is None:
                    owned.terminate()
                    try:
                        owned.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        owned.kill(); owned.wait(timeout=3)


if __name__ == "__main__":
    unittest.main()
