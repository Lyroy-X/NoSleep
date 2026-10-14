#!/usr/bin/env python3
"""Compile/test the bridge's fake contracts; never touch actual power on MAIN."""
import hashlib
import json
import platform
from pathlib import Path
import subprocess
import unittest
import uuid

REPO = Path(__file__).resolve().parents[1]
SOURCE = REPO / 'infra/power-handoff/bridge.swift'


class PowerHandoffContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.evidence = REPO / 'build/power-handoff-contract' / uuid.uuid4().hex
        cls.evidence.mkdir(parents=True, mode=0o700)
        cls.binary = cls.evidence / 'bridge'
        cls.source_sha256 = hashlib.sha256(SOURCE.read_bytes()).hexdigest()
        cls.compile = subprocess.run(['swiftc', '-target', platform.machine() + '-apple-macos14.0',
                                     '-parse-as-library', str(SOURCE), '-o', str(cls.binary)],
                                     capture_output=True, timeout=60)
        if cls.compile.returncode:
            (cls.evidence / 'compile.log').write_bytes(cls.compile.stdout + cls.compile.stderr)
            raise RuntimeError('Bridge compilation failed; private compile log retained')

    def test_fake_power_and_identity_contracts_without_io_calls(self):
        result = subprocess.run([str(self.binary), '--self-test'], capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0)
        self.assertIn(b'PASS: bridge refusal at SleepDisabled0', result.stdout)
        self.assertIn(b'PID reuse and stopped-old rollback guards', result.stdout)
        self.assertIn(b'pinned displayOFF/displayON minimum assertions', result.stdout)
        self.assertIn(b'target crash keeps holding', result.stdout)
        self.assertIn(b'observed failure then restoration vetoes all three release actions', result.stdout)
        self.assertIn(b'failed persistence holds and cannot PASS', result.stdout)

    def test_native_file_and_directory_fsync_with_failed_sink_keeps_fake_assertions(self):
        directory = self.evidence / 'durability'
        directory.mkdir(mode=0o700)
        result = subprocess.run([str(self.binary), '--persistence-test', '--state-dir', str(directory)],
                                capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))
        facts = json.loads(result.stdout)
        self.assertEqual(facts['scope'], 'owned-filesystem-and-fake-power-only')
        self.assertTrue(facts['fileAndDirectoryFsyncExecuted'])
        self.assertTrue(facts['failureEventAndAtomicSnapshotReadBack'])
        self.assertTrue(facts['interruptedReplacementPreservedFailure'])
        self.assertTrue(facts['failedPersistenceKeepsAssertions'])
        self.assertEqual(facts['realPowerActions'], 0)
        (self.evidence / 'durability-facts.json').write_text(json.dumps(facts, indent=2))

    def test_missing_or_non_boolean_display_intent_refuses_before_power_access(self):
        arguments = ['--hold', '--old-pid', '10001', '--old-executable', '/owned/old',
                     '--old-sha256', 'a' * 64, '--new-executable', '/owned/new',
                     '--new-sha256', 'b' * 64, '--state-dir', str(self.evidence),
                     '--session', str(uuid.uuid4())]
        for suffix in [[], ['--wanted-display', ''], ['--wanted-display', 'false'],
                       ['--wanted-display', '2'], ['--wanted-display', '01'],
                       ['--wanted-display', '0', '--wanted-display', '1']]:
            with self.subTest(suffix=suffix):
                result = subprocess.run([str(self.binary), *arguments, *suffix],
                                        capture_output=True, timeout=5)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(json.loads(result.stdout), {'bridgeRefused': True,
                                 'reason': 'invalidArguments', 'globalPowerWrites': 0})
                self.assertFalse((self.evidence / 'state.json').exists())

    def test_default_and_incomplete_modes_refuse_before_holding_assertions(self):
        for arguments in [[], ['--hold'], ['--unknown']]:
            with self.subTest(arguments=arguments):
                result = subprocess.run([str(self.binary), *arguments], capture_output=True, timeout=5)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(json.loads(result.stdout), {'bridgeRefused': True, 'reason': 'invalidArguments', 'globalPowerWrites': 0})

    def test_bridge_has_no_global_setter_or_process_signal_sender(self):
        source = SOURCE.read_text()
        for forbidden in ['IORegistryEntrySetCFProperty', 'IOPMSet', '/usr/bin/pmset', '/usr/bin/sudo',
                          'disablesleep', 'shutdownNow', 'NSRunningApplication', 'kill(', 'setBlocked(']:
            self.assertNotIn(forbidden, source)
        self.assertIn('guard try power.sleepDisabled()', source)
        self.assertIn('private(set) var owned', source)
        self.assertIn('for id in owned { power.release(id) }', source)
        for interruption in ['SIGINT', 'SIGTERM', 'SIGHUP']:
            self.assertIn('signal(' + interruption + ', SIG_IGN)', source)
        self.assertIn('while !bridge.owned.isEmpty', source)
        self.assertEqual(hashlib.sha256(SOURCE.read_bytes()).hexdigest(), self.source_sha256,
                         'Bridge source changed after compilation; repeat the current-input check')

    @classmethod
    def tearDownClass(cls):
        receipt = {'scope': 'compiled bridge + injected fake power/identity contracts only; no MAIN/VM power calls',
                   'sourceSHA256': cls.source_sha256,
                   'sourceChangedDuringRun': hashlib.sha256(SOURCE.read_bytes()).hexdigest() != cls.source_sha256,
                   'binarySHA256': hashlib.sha256(cls.binary.read_bytes()).hexdigest(),
                   'compiled': cls.compile.returncode == 0, 'mainPowerActions': 0, 'mainProcessActions': 0}
        receipt['wantedDisplayIntentsCovered'] = [False, True]
        receipt['actualOldNewHandoffProven'] = False
        receipt['stickyFailureAndFinalProofContractsCovered'] = True
        receipt['nativeFilesystemFsyncTestUsesOnlyFakePower'] = True
        (cls.evidence / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
        print('Bridge contract evidence: ' + str(cls.evidence))


if __name__ == '__main__':
    unittest.main(verbosity=2)
