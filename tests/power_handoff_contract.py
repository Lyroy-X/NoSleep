#!/usr/bin/env python3
"""Compile/test the bridge's fake contracts; never touch actual power on MAIN."""
import copy
import io
import importlib.util
import signal
import sys
import zipfile
from unittest.mock import patch
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



def load_owned_module(name, filename):
    spec = importlib.util.spec_from_file_location(name, REPO / 'infra/power-handoff' / filename)
    module = importlib.util.module_from_spec(spec); sys.modules[name] = module; spec.loader.exec_module(module)
    return module


class FakeOwnedBindings:
    def __init__(self, module, display):
        self.m = module; self.display = display; self.global_value = False
        self.values = {module.KEYS[0]: {'present': False}, module.KEYS[1]: {'present': True, 'value': False},
                       module.KEYS[2]: {'present': True, 'value': False}}
        self.original = copy.deepcopy(self.values); self.apps = {}; self.bridges = {}; self.counter = 1000
        self.signals = []; self.installed = None; self.notify = None; self.force_request_timeout = False
        self.force_start_timeout = False

    def guard(self): pass
    def sample(self, pid=0):
        return {'sleepDisabled': self.global_value, 'noSleepPIDs': sorted(self.apps),
                'bridgePIDs': [pid for pid, actor in self.bridges.items() if actor['live']],
                'process': copy.deepcopy(self.apps.get(pid))}
    def preferences(self): return copy.deepcopy(self.values)
    def write_preferences(self, value):
        if value == self.original:
            assert not self.apps and not any(actor['live'] for actor in self.bridges.values())
        self.values = copy.deepcopy(value)
    def install_kind(self, kind):
        assert not self.apps; self.installed = kind
    def launch(self, kind):
        assert self.installed == kind and not self.apps
        self.counter += 1
        value = {'pid': self.counter, 'executable': '/owned/install/NoSleep.app/Contents/MacOS/NoSleep',
                 'sha256': kind, 'startSeconds': self.counter, 'startMicroseconds': 1, 'status': 2}
        self.apps[value['pid']] = value.copy(); self.global_value = True
        self.notify('app', value.copy())
        return value
    def ready(self, identity, display):
        assert self.m.same_lifetime(self.apps.get(identity['pid']), identity)
        assert self.apps[identity['pid']]['status'] != 4 and display == self.display and self.global_value
        assert self.values[self.m.KEYS[0]]['value'] and self.values[self.m.KEYS[1]]['value'] == display
        assert self.values[self.m.KEYS[2]]['value'] is False
        return {'sleepDisabled': True, 'idleOn': True, 'displayOn': display}
    def signal(self, identity, value):
        assert self.m.same_lifetime(self.apps.get(identity['pid']), identity)
        self.signals.append((identity['pid'], value))
        if value == signal.SIGKILL: del self.apps[identity['pid']]
        else: self.apps[identity['pid']]['status'] = 4 if value == signal.SIGSTOP else 2
    def wait_status(self, identity, stopped):
        assert (self.apps[identity['pid']]['status'] == 4) == stopped
    def absent(self, identity): assert identity['pid'] not in self.apps
    def start_bridge(self, old, display, case):
        self.counter += 1
        actor = {'pid': self.counter, 'session': case, 'old': old, 'live': True, 'wantedDisplay': display}
        self.bridges[actor['pid']] = actor; self.notify('bridge', actor.copy())
        if self.force_start_timeout: raise self.m.Refused('bridge-start-timeout')
        return actor
    def bridge_held(self, actor): assert self.bridges[actor['pid']]['live'] and self.global_value
    def request(self, actor, action, pid=None, expect_refusal=False):
        self.bridge_held(actor)
        if self.force_request_timeout: raise self.m.Refused('bridge-observation-timeout')
        old = actor['old']; target = self.apps.get(old['pid'] if action == 'abort-old-resumed' else pid)
        refused = target is None or target['status'] == 4
        if expect_refusal:
            assert refused; return {'phase': 'holding'}
        assert not refused
        if action == 'abort-old-resumed':
            assert self.m.same_lifetime(target, old); phase = 'released-to-old'
        elif action == 'rollback-old-restarted':
            assert target['sha256'] == 'old' and not self.m.same_lifetime(target, old); phase = 'released-to-restarted-old'
        else:
            assert target['sha256'] == 'new'; phase = 'released-to-new'
        self.bridges[actor['pid']]['live'] = False
        return {'phase': phase}
    def nonce(self): return {'matched': True, 'runMatched': True, 'tunnelRoute': True, 'challengeSHA256': '0' * 64}
    def restore_global(self, prior):
        assert not self.apps and not any(actor['live'] for actor in self.bridges.values()); self.global_value = prior


class OwnedHandoffRunnerContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.guest = load_owned_module('owned_power_guest_tests', 'guest_operator.py')
        cls.host = load_owned_module('owned_power_host_tests', 'run_owned_vm.py')
        cls.evidence = REPO / 'build/power-handoff-review' / ('runner-contract-' + uuid.uuid4().hex)
        cls.evidence.mkdir(mode=0o700, parents=True)
        cls.probe = cls.evidence / 'probe'
        result = subprocess.run(['swiftc', '-target', 'arm64-apple-macos14.0', '-parse-as-library',
                     str(REPO/'infra/power-handoff/owned_vm_probe.swift'), '-o', str(cls.probe)], capture_output=True, timeout=60)
        if result.returncode:
            (cls.evidence/'compile.log').write_bytes(result.stdout + result.stderr)
            raise RuntimeError('Independent read-only probe failed to compile')

    def config(self, display=False):
        return {'schema': 1, 'execution': str(uuid.uuid4()), 'vm': self.guest.VM, 'mac': self.guest.MAC,
            'run': self.guest.RUN, 'wantedDisplay': display, 'requireConnectedTunnel': True,
            'manifestSHA256': 'a'*64, 'artifacts': {name: {'file': 'guest_operator.py' if name=='operator' else name + ('.zip' if name in ('old','new') else '.bin'),
                'sha256': 'b'*64, **({'executableSHA256':self.guest.OLD_SHA if name=='old' else 'c'*64,'infoSHA256':'d'*64} if name in ('old','new') else {})}
                for name in ('old','new','bridge','probe','operator')}}

    def test_transferred_operator_name_does_not_shadow_python_standard_library(self):
        original=(REPO/'infra/power-handoff/guest_operator.py').read_bytes()
        for filename, accepted in [('operator.py',False), ('guest_operator.py',True)]:
            directory=self.evidence/('module-shadow-'+filename);directory.mkdir(mode=0o700)
            script=directory/filename;script.write_bytes(original)
            result=subprocess.run([sys.executable,'-S',str(script),'--help'],cwd=directory,
                                  capture_output=True,timeout=5)
            if accepted:
                self.assertEqual(result.returncode,0)
                self.assertIn(b'--execute',result.stdout)
            else:
                self.assertNotEqual(result.returncode,0)
                self.assertIn(b'AttributeError',result.stderr)
        config=self.config();config['artifacts']['operator']['file']='operator.py'
        with self.assertRaises(self.guest.Refused):self.guest.validate_config(config)
        called=[]
        class FakeGuest:
            def run(self,script,**kwargs):called.append(script);return 0,'{}'
        self.host.invoke(FakeGuest(),{'execution':'id','configSHA256':'a'*64},True)
        self.assertIn('/guest_operator.py',called[0]);self.assertNotIn('/operator.py',called[0])

    def test_production_request_matches_swift_uppercase_uuid_in_state_and_release_events(self):
        request=uuid.UUID('b23cc7fc-e46c-44e1-a1b6-5aec569313ca')
        for action,phase in [('abort-old-resumed','released-to-old'),('release-new','released-to-new'),
                             ('rollback-old-restarted','released-to-restarted-old')]:
            directory=self.evidence/('uuid-'+action);directory.mkdir(mode=0o700)
            actor={'pid':42,'directory':str(directory),'session':str(uuid.uuid4()),'wantedDisplay':False}
            bindings=object.__new__(self.guest.GuestBindings)
            bindings.bridge_held=lambda actor:None
            bindings.state=lambda actor:{'request':str(request).upper(),'phase':phase,
                                         'lastCommand':'accepted','ownAssertionsOn':False}
            bindings.events=lambda actor:[{'kind':'released','request':str(request).upper()}]
            bindings.sample=lambda pid:{'process':None}
            class TerminalChild:
                def wait(self,timeout):return 0
            bindings.bridges={42:TerminalChild()}
            with patch.object(self.guest.uuid,'uuid4',return_value=request):
                self.assertEqual(bindings.request(actor,action,43)['phase'],phase)
            self.assertEqual(json.loads((directory/'command.json').read_text())['request'],str(request))
        bindings.state=lambda actor:{'request':str(request).upper(),'phase':'holding','lastCommand':'targetProofFailed'}
        with patch.object(self.guest.uuid,'uuid4',return_value=request):
            self.assertEqual(bindings.request(actor,'release-new',43,expect_refusal=True)['phase'],'holding')
        self.assertFalse(self.guest.same_request(str(request),'f23cc7fc-e46c-44e1-a1b6-5aec569313ca'))
        self.assertFalse(self.guest.same_request('invalid',str(request)))
        self.assertFalse(self.guest.same_request(None,str(request)))
        invalid_spellings=[request.hex,'{'+str(request)+'}','urn:uuid:'+str(request),
                           str(request)+' ',str(request)+'\n',str(request).replace('-','--')]
        for malformed in invalid_spellings:
            with self.subTest(malformed=malformed):
                self.assertFalse(self.guest.same_request(malformed,str(request)))
                self.assertFalse(self.guest.same_request(str(request),malformed))
                bindings.state=lambda actor:{'request':malformed,'phase':'released-to-new',
                                             'lastCommand':'accepted','ownAssertionsOn':False}
                with patch.object(self.guest.uuid,'uuid4',return_value=request), \
                     patch.object(self.guest.time,'monotonic',side_effect=[0,0,11]), \
                     patch.object(self.guest.time,'sleep'):
                    with self.assertRaisesRegex(self.guest.Refused,'bridge-observation-timeout'):
                        bindings.request(actor,'release-new',43)
                bindings.state=lambda actor:{'request':str(request).upper(),'phase':'released-to-new',
                                             'lastCommand':'accepted','ownAssertionsOn':False}
                bindings.events=lambda actor:[{'kind':'released','request':malformed}]
                with patch.object(self.guest.uuid,'uuid4',return_value=request):
                    with self.assertRaisesRegex(self.guest.Refused,'bridge-events-refused'):
                        bindings.request(actor,'release-new',43)

    def test_production_readiness_pins_historical_schema_and_requires_new_recovery_field(self):
        config = self.config(); fields = {'sleepChecked':True, 'displayChecked':False,
            'windowVisible':True, 'setupVisible':False, 'errorText':''}
        preferences = {self.guest.KEYS[0]:{'present':True,'value':True},
            self.guest.KEYS[1]:{'present':True,'value':False}, self.guest.KEYS[2]:{'present':True,'value':False}}
        ui = self.evidence/'schema-ui.json'
        for kind, recovery, accepted in [('old',None,True), ('new',None,False),
                                         ('old',True,False), ('new',False,True)]:
            with self.subTest(kind=kind,recovery=recovery):
                current = fields.copy()
                if recovery is not None: current['recoveryEnabled'] = recovery
                ui.write_text(json.dumps(current))
                identity={'pid':1001,'sha256':config['artifacts'][kind]['executableSHA256']}
                bindings=object.__new__(self.guest.GuestBindings)
                bindings.config=config; bindings.launch_times={1001:0}
                bindings.sample=lambda pid:{'process':identity,'noSleepPIDs':[1001],
                    'sleepDisabled':True,'idleOn':True,'displayOn':False}
                bindings.preferences=lambda:preferences
                with patch.object(self.guest,'Path',return_value=ui), \
                     patch.object(self.guest.time,'monotonic',side_effect=[0,0,16]), \
                     patch.object(self.guest.time,'sleep'):
                    if accepted: self.assertTrue(bindings.ready(identity,False)['idleOn'])
                    else:
                        with self.assertRaises(self.guest.Refused): bindings.ready(identity,False)
        for changed in ({**preferences,self.guest.KEYS[2]:{'present':False}},
                        {**preferences,self.guest.KEYS[2]:{'present':True,'value':True}}):
            self.assertFalse(self.guest.app_ui_ready(fields,self.guest.OLD_SHA,config,changed))
        with self.assertRaises(self.guest.Refused):
            self.guest.app_ui_ready(fields,'f'*64,config,preferences)

    def test_readonly_inspection_samples_current_app_and_refuses_reused_or_provisional_lifetime(self):
        expected = {'pid':1001,'executable':'/owned/NoSleep','sha256':self.guest.OLD_SHA,
                    'startSeconds':100,'startMicroseconds':1,'status':2}
        class ProbeOnly:
            def __init__(self,current): self.current=current; self.sampled=[]
            def sample(self,pid=0):
                self.sampled.append(pid)
                return {'process':self.current if pid else None,'sleepDisabled':True,
                        'idleOn':True,'displayOn':False,'noSleepPIDs':[1001]}
            def preferences(self): return {}
        for changes, matched in [({},True),({'status':4},True),({'startSeconds':101},False),
                                 ({'sha256':'f'*64},False),({'executable':'/foreign/NoSleep'},False)]:
            probe=ProbeOnly({**expected,**changes})
            value=self.guest.inspection(probe,self.config(),{'currentApp':expected})
            self.assertEqual(value['currentAppLifetimeMatches'],matched)
            self.assertEqual(value['currentApp'],probe.current)
            self.assertEqual(value['currentAppSnapshot']['process'],probe.current)
            self.assertFalse(value['currentAppCheckpointProvisional'])
            self.assertEqual(probe.sampled,[0,1001])
        probe=ProbeOnly(expected)
        value=self.guest.inspection(probe,self.config(),{'currentApp':{'pid':1001,'sha256':self.guest.OLD_SHA}})
        self.assertTrue(value['currentAppCheckpointProvisional'])
        self.assertFalse(value['currentAppLifetimeMatches'])
        for actor, current, matched, provisional in [
            ({'pid':1001,'directory':'/owned/bridge','session':'session','wantedDisplay':False,
              'identity':expected},expected,True,False),
            ({'pid':1001,'directory':'/owned/bridge','session':'session','wantedDisplay':False},expected,False,True),
            ({'pid':1001,'identity':expected},{**expected,'startSeconds':101},False,False)]:
            probe=ProbeOnly(current)
            value=self.guest.inspection(probe,self.config(),{'activeBridge':actor})
            self.assertEqual(value['currentBridgeLifetimeMatches'],matched)
            self.assertEqual(value['currentBridgeCheckpointProvisional'],provisional)
            self.assertEqual(value['currentBridge'],current)

    def test_full_production_operator_flow_for_both_display_intents_uses_exact_actor_signals(self):
        for display in (False, True):
            bindings = FakeOwnedBindings(self.guest, display); checkpoints = []
            runner = self.guest.HandoffRunner(bindings, self.config(display), lambda value: checkpoints.append(copy.deepcopy(value)))
            result = runner.execute()
            self.assertTrue(result['fullHandoffProven']); self.assertEqual(result['result'], 'passed')
            self.assertEqual([case['case'] for case in result['caseReceipts']], ['abort','replace','restart'])
            self.assertEqual([case['finalPhase'] for case in result['caseReceipts']],
                ['released-to-old','released-to-new','released-to-restarted-old'])
            self.assertEqual(bindings.preferences(), bindings.original); self.assertFalse(bindings.global_value)
            self.assertTrue(result['preferenceRestored'] and result['priorGlobalRestored'])
            self.assertEqual(sum(sig == signal.SIGSTOP for _,sig in bindings.signals), 4)
            self.assertEqual(sum(sig == signal.SIGCONT for _,sig in bindings.signals), 1)
            self.assertTrue(any(value['phase'] == 'bridge-spawned-checkpoint' for value in checkpoints))
            self.assertFalse(any(actor['live'] for actor in bindings.bridges.values()))

    def test_timeout_retains_the_same_bridge_app_checkpoint_and_does_not_restore_or_retry(self):
        for stage in ('start','request'):
            bindings = FakeOwnedBindings(self.guest, False)
            bindings.force_start_timeout = stage == 'start'; bindings.force_request_timeout = stage == 'request'
            checkpoints = []; runner = self.guest.HandoffRunner(bindings, self.config(), lambda value: checkpoints.append(copy.deepcopy(value)))
            result = runner.execute()
            self.assertEqual(result['result'], 'failed'); self.assertFalse(result['fullHandoffProven'])
            self.assertTrue(result['restorationDeferred']); self.assertEqual(result['phase'], 'failed-holding')
            self.assertIsNotNone(result['activeBridge']); self.assertTrue(bindings.bridges[result['activeBridge']['pid']]['live'])
            self.assertEqual(len(bindings.bridges), 1); self.assertTrue(bindings.apps)
            self.assertFalse(result['preferenceRestored'] or result['priorGlobalRestored'])
            self.assertFalse(any(sig == signal.SIGKILL for _,sig in bindings.signals))

    def test_missing_display_and_foreign_mac_or_non_tunnel_config_refuse(self):
        for mutate in (lambda v:v.pop('wantedDisplay'), lambda v:v.update(wantedDisplay=0),
                       lambda v:v.update(mac='00:00:00:00:00:00'),lambda v:v.update(requireConnectedTunnel=False),
                       lambda v:v.update(schema=True)):
            config=self.config(); mutate(config)
            with self.assertRaises(self.guest.Refused): self.guest.validate_config(config)
        self.guest.validate_config(self.config())

    def test_fresh_bridge_state_requires_pinned_intent_and_every_sticky_flag(self):
        value={'session':'case','wantedDisplay':False,'phase':'holding','sleepDisabled':True,
               **{key:False for key in self.guest.FLAGS}}
        self.guest.bridge_state(value,'case',False,'holding')
        for flag in self.guest.FLAGS:
            failed=value.copy();failed[flag]=True
            with self.assertRaises(self.guest.Refused): self.guest.bridge_state(failed,'case',False,'holding')
        with self.assertRaises(self.guest.Refused): self.guest.bridge_state(value,'case',True,'holding')

    def test_zip_traversal_and_symlink_refuse_before_extraction(self):
        for kind in ('traversal','symlink'):
            archive=self.evidence/(kind+'.zip')
            with zipfile.ZipFile(archive,'w') as package:
                name='NoSleep.app/../../escape' if kind=='traversal' else 'NoSleep.app/Contents/link'
                item=zipfile.ZipInfo(name)
                if kind=='symlink': item.external_attr=(0o120777 << 16)
                package.writestr(item,b'bad')
            with self.assertRaises(self.guest.Refused): self.guest.safe_extract(archive,self.evidence/kind)
            self.assertFalse((self.evidence/'escape').exists())

    def test_provisional_spawn_identity_is_retained_not_unsafely_killed(self):
        bindings=FakeOwnedBindings(self.guest,False)
        def uncertain(kind):
            value={'pid':1234,'executable':'/owned/install/NoSleep.app/Contents/MacOS/NoSleep','sha256':'old'}
            bindings.apps[value['pid']]=value.copy();bindings.notify('app',value)
            raise self.guest.Refused('app-identity-refused')
        bindings.launch=uncertain
        result=self.guest.HandoffRunner(bindings,self.config(),lambda value:None).execute()
        self.assertFalse(result['fullHandoffProven']);self.assertTrue(result['restorationDeferred'])
        self.assertEqual(result['phase'],'failed-app-identity-unconfirmed');self.assertEqual(bindings.signals,[])

    def test_read_only_probe_self_test_has_no_real_runtime_access(self):
        result=subprocess.run([str(self.probe),'--self-test'],capture_output=True,timeout=5)
        self.assertEqual(result.returncode,0)
        self.assertIn(b'no hardware/power/preferences calls',result.stdout)

    def test_host_cli_without_opt_in_cannot_load_runtime(self):
        with patch.object(self.host,'runtime',side_effect=AssertionError('Runtime used')) as runtime:
            with patch.object(sys,'argv',['run_owned_vm.py']), patch.object(sys,'stderr',io.StringIO()):
                with self.assertRaises(SystemExit): self.host.main()
            runtime.assert_not_called()

    def test_manifest_binds_current_sources_to_exact_candidate_build_and_frozen_bridge(self):
        old={'path':'/owned/old.zip','sha256':'a'*64,'executableSHA256':self.host.OLD_SHA,'infoSHA256':'c'*64}
        new={'path':'/owned/new.zip','sha256':'b'*64,'executableSHA256':'d'*64,'infoSHA256':'e'*64}
        source={'Sources/NoSleep.swift':'f'*64}; runner={'infra/power-handoff/guest_operator.py':'0'*64}
        manifest={'schema':1,'wantedDisplay':False,'requireConnectedTunnel':True,'sourceHashes':source,
            'runnerHashes':runner,'bridgeSourceSHA256':self.host.BRIDGE_SOURCE_SHA,
            'candidateBuildReceipt':{'path':'/owned/build.json','sha256':'1'*64},
            'artifacts':{'old':old,'new':new,'bridge':{'path':'/owned/bridge.bin','sha256':self.host.BRIDGE_BINARY_SHA}}}
        build={'sourceHashes':source,'binarySHA256':'d'*64,'infoSHA256':'e'*64}
        def hashes(path):
            return self.host.BRIDGE_SOURCE_SHA if Path(path).name=='bridge.swift' else self.host.BRIDGE_BINARY_SHA
        with patch.object(self.host,'sources',return_value=source), patch.object(self.host,'runner_sources',return_value=runner), \
             patch.object(self.host,'digest',side_effect=hashes), patch.object(self.host,'owned_file',side_effect=lambda path,*args:Path(path)), \
             patch.object(self.host,'archive_facts',side_effect=lambda path:old if path==old['path'] else new), \
             patch.object(self.host,'read_hashed',return_value=build):
            self.host.validate_manifest(manifest)
            for mutation in (lambda v:v.update(sourceHashes={}), lambda v:v.update(wantedDisplay=0),
                             lambda v:v.update(bridgeSourceSHA256='2'*64)):
                changed=copy.deepcopy(manifest); mutation(changed)
                with self.assertRaises(self.host.Refused): self.host.validate_manifest(changed)
            with patch.object(self.host,'read_hashed',return_value={**build,'binarySHA256':'3'*64}):
                with self.assertRaises(self.host.Refused): self.host.validate_manifest(manifest)

    @classmethod
    def tearDownClass(cls):
        paths=[REPO/'infra/power-handoff'/name for name in ('run_owned_vm.py','guest_operator.py','owned_vm_probe.swift')]
        receipt={'scope':'production runner flow contracts with fake bindings + compiled read-only probe self-test only',
                 'sourceSHA256':{str(p.relative_to(REPO)):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths},
                 'probeSHA256':hashlib.sha256(cls.probe.read_bytes()).hexdigest(),'actualVMHandoffExecuted':False,
                 'mainActions':0,'vmActions':0,'realPowerActions':0,'realProcessSignals':0}
        (cls.evidence/'receipt.json').write_text(json.dumps(receipt,indent=2))
        print('Owned runner contract evidence: '+str(cls.evidence))


if __name__ == '__main__':
    unittest.main(verbosity=2)
