#!/usr/bin/env python3
"""Validate compact UI acceptance on actual native CI lanes and reject faulty copies."""
import copy
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]


class CompactCI(unittest.TestCase):
    def contract(self, workflow):
        self.assertEqual(workflow['jobs']['quality']['runs-on'], 'macos-15', 'native red-green proof requires AppKit')
        native = workflow['jobs']['native-regression']
        for job in workflow['jobs'].values():
            self.assertEqual(job['runs-on'], 'macos-15', 'Intel execution is disabled for every CI entry point')
            self.assertNotIn('strategy', job, 'No hidden Intel matrix may be scheduled')
        self.assertFalse(native.get('continue-on-error', False))
        steps = native['steps']
        runs = [(i, step) for i, step in enumerate(steps) if 'run' in step]
        ui = [(i, step) for i, step in runs if './scripts/test.sh' in step['run']]
        mutations = [(i, step) for i, step in runs if 'compact_status_mutation.py' in step['run']]
        self.assertEqual(len(ui), 1)
        self.assertEqual(len(mutations), 1)
        self.assertEqual(ui[0][1]['run'], './scripts/test.sh --local > build/ci/regression.log 2>&1')
        self.assertEqual(mutations[0][1]['run'], 'python3 tests/compact_status_mutation.py')
        self.assertGreater(mutations[0][0], ui[0][0])
        for _, step in ui + mutations:
            self.assertNotIn('if', step)
            self.assertFalse(step.get('continue-on-error', False))
        self.assertEqual(set(workflow['jobs']['package']['needs']), {'quality', 'native-regression'})

    def test_real_workflow_runs_ui_and_assertion_mutation_on_arm_only(self):
        self.contract(yaml.safe_load((ROOT / '.github/workflows/regression.yml').read_text()))

    def test_faulty_ui_scheduling_is_rejected_by_assertion(self):
        original = yaml.safe_load((ROOT / '.github/workflows/regression.yml').read_text())
        self.contract(original)
        for fault in ['missing-ui', 'missing-mutation', 'skip-mutation', 'ignore-failure', 'intel-runner', 'intel-matrix']:
            with self.subTest(fault=fault):
                bad = copy.deepcopy(original)
                native = bad['jobs']['native-regression']
                ui = next(step for step in native['steps'] if './scripts/test.sh' in step.get('run', ''))
                mutation = next(step for step in native['steps'] if 'compact_status_mutation.py' in step.get('run', ''))
                if fault == 'missing-ui':
                    ui['run'] = ui['run'].replace('--local', '--ci')
                elif fault == 'missing-mutation':
                    native['steps'].remove(mutation)
                elif fault == 'skip-mutation':
                    mutation['if'] = 'false'
                elif fault == 'ignore-failure':
                    ui['continue-on-error'] = True
                elif fault == 'intel-runner':
                    native['runs-on'] = 'macos-15-intel'
                else:
                    native['strategy'] = {'matrix': {'runner': ['macos-15', 'macos-15-intel']}}
                with self.assertRaises(AssertionError):
                    self.contract(bad)

    def test_validator_installer_selects_verified_native_architectures_and_refuses_unknown(self):
        workflow = yaml.safe_load((ROOT / '.github/workflows/regression.yml').read_text())
        script = next(step['run'] for step in workflow['jobs']['quality']['steps'] if step.get('name') == 'Install verified workflow validator')
        expected = {'arm64': ('arm64', 'aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f'),
                    'x86_64': ('amd64', '5b44c3bc2255115c9b69e30efc0fecdf498fdb63c5d58e17084fd5f16324c644')}
        def run(candidate, architecture):
            with tempfile.TemporaryDirectory(prefix='nosleep-validator-fixture-') as folder:
                private = Path(folder); tools = private / 'bin'; tools.mkdir(); log = private / 'calls.log'
                for name in ['uname', 'curl', 'shasum', 'tar']:
                    executable = tools / name
                    executable.write_text('#!/usr/bin/env python3\nimport os,sys\nfrom pathlib import Path\n'
                        'name=Path(sys.argv[0]).name\n'
                        'if name=="uname":print(os.environ["VALIDATOR_TEST_ARCH"])\n'
                        'else:\n'
                        ' with open(os.environ["VALIDATOR_TEST_LOG"],"a") as log:log.write(name+" "+" ".join(sys.argv[1:])+" "+(sys.stdin.read() if name=="shasum" else "")+"\\n")\n')
                    executable.chmod(0o700)
                result = subprocess.run(['bash', '-e', '-c', candidate], cwd=private,
                    env={**os.environ, 'PATH': str(tools) + os.pathsep + os.environ['PATH'],
                         'VALIDATOR_TEST_ARCH': architecture, 'VALIDATOR_TEST_LOG': str(log)},
                    capture_output=True, text=True, timeout=10)
                return result.returncode, log.read_text() if log.exists() else ''
        for architecture, (archive, checksum) in expected.items():
            code, calls = run(script, architecture)
            self.assertEqual(code, 0)
            self.assertIn('actionlint_1.7.12_darwin_' + archive + '.tar.gz', calls)
            self.assertIn(checksum + '  build/tools/actionlint.tar.gz', calls)
            self.assertIn('shasum --algorithm 256 --check', calls)
        code, calls = run(script, 'unknown')
        self.assertNotEqual(code, 0)
        self.assertEqual(calls, '')
        faulty = script.replace('*) exit 1 ;;', '*) validator_arch=arm64; validator_sha=' + expected['arm64'][1] + ' ;;')
        code, _ = run(faulty, 'unknown')
        with self.assertRaises(AssertionError):
            self.assertNotEqual(code, 0, 'faulty unknown-architecture fallback must be rejected')


if __name__ == '__main__':
    unittest.main()
