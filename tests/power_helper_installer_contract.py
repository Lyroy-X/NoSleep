#!/usr/bin/env python3
"""Exercise the installer's privileged command with owned paths and fake tools only."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'scripts/install-power-helper.command'


class InstallerContract(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='nosleep-installer-contract-')
        self.directory = Path(self.tmp.name)
        # Capture the exact zsh argv at the privilege boundary; never execute sudo.
        fake_sudo = self.directory / 'sudo'
        fake_sudo.write_text('#!/usr/bin/env python3\nimport json,os,sys\n'
                             'open(os.environ["CAPTURE"],"w").write(json.dumps(sys.argv[1:]))\n')
        fake_sudo.chmod(0o700)
        capture = self.directory / 'command.json'
        result = subprocess.run(['/bin/zsh', str(SOURCE)], input='yes\n\n', text=True,
                                capture_output=True, timeout=5,
                                env={**os.environ, 'PATH': str(self.directory) + ':' + os.environ['PATH'],
                                     'CAPTURE': str(capture)})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(capture.exists(), 'Expected the single mocked privilege boundary')
        argv = json.loads(capture.read_text())
        self.assertEqual(argv[:2], ['/bin/zsh', '-c'])
        self.body = argv[2]
        self.assertEqual(argv[3], '--')
        self.stage = self.directory / 'root-stage'
        self.destination = self.directory / 'rules'
        self.destination.mkdir()
        self.events = self.directory / 'events.jsonl'
        fake = self.directory / 'tool'
        fake.write_text('''#!/usr/bin/env python3
import json,os,pathlib,sys
op,*args=sys.argv[1:]
stage=pathlib.Path(os.environ['STAGE'])
if op=='mktemp':
 stage.mkdir(mode=0o700); print(stage)
else:
 rule=pathlib.Path(args[-1] if op=='visudo' else args[-2])
 text=rule.read_text()
 assert text=='friend.test ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0\\n'
 assert stage.stat().st_mode & 0o777 == 0o700
 with open(os.environ['EVENTS'],'a') as f: f.write(json.dumps({'op':op,'rule':text})+'\\n')
 if op=='install': pathlib.Path(args[-1]).write_text(text)
''')
        fake.chmod(0o700)
        self.qualified = self.body.replace('/private/etc/sudoers.d', str(self.destination))
        for tool in ('mktemp', 'visudo', 'install'):
            prefix = '/usr/sbin/' if tool == 'visudo' else '/usr/bin/'
            self.qualified = self.qualified.replace(prefix + tool, str(fake) + ' ' + tool)

    def tearDown(self):
        self.tmp.cleanup()

    def run_body(self, account='friend.test', uid='501'):
        return subprocess.run(['/bin/zsh', '-c', self.qualified, '--', account, uid],
                              capture_output=True, text=True, timeout=5,
                              env={**os.environ, 'STAGE': str(self.stage), 'EVENTS': str(self.events)})

    def test_rule_is_created_validated_and_installed_inside_one_privilege_boundary(self):
        source = SOURCE.read_text()
        self.assertNotIn('mktemp', source[:source.index('sudo /bin/zsh -c')])
        self.assertIn('umask 077', self.body)
        result = self.run_body()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([json.loads(line)['op'] for line in self.events.read_text().splitlines()],
                         ['visudo', 'install', 'visudo'])
        self.assertTrue((self.destination / 'nosleep_501').is_file())
        self.assertFalse(self.stage.exists(), 'Owned staging must be cleaned on success')

    def test_privileged_validation_refuses_injection_and_root_before_staging(self):
        for account, uid in [('friend; ALL', '501'), ('friend\nALL', '501'),
                             ('friend.test', '0'), ('friend.test', '501;echo')]:
            with self.subTest(account=account, uid=uid):
                self.assertNotEqual(self.run_body(account, uid).returncode, 0)
                self.assertFalse(self.stage.exists())
                self.assertFalse(self.events.exists())

    def test_existing_rule_or_symlink_is_not_overwritten(self):
        rule = self.destination / 'nosleep_501'
        for symlink in (False, True):
            if symlink:
                rule.symlink_to(self.directory / 'missing')
            else:
                rule.write_text('existing rule')
            self.assertNotEqual(self.run_body().returncode, 0)
            self.assertFalse(self.stage.exists())
            self.assertFalse(self.events.exists())
            if not symlink:
                self.assertEqual(rule.read_text(), 'existing rule')
            rule.unlink()


if __name__ == '__main__':
    unittest.main()
