#!/usr/bin/env python3
"""Opt-in owned-VM operator; no Cisco/auth changes and no host fallback.

Only --execute invokes runtime actions. Every mutation rechecks VirtualMac/MAC/
console, exact process lifetime and frozen owned paths. A failure with a live
bridge retains actors and checkpoint for inspection, never blind retry/cleanup.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import selectors
import shutil
import signal
import stat
import subprocess
import time
import uuid
import zipfile

MAC = '42:35:8c:14:fd:0c'
VM = 'nosleep-vpn-lab-20261012'
RUN = 'f0b5145836a1'
ROOT = Path('/Users/admin/NoSleepLab/power-handoff')
DOMAIN = 'local.robert.keepawake'
KEYS = ('PreventSystemSleep', 'KeepDisplayAwake', 'CiscoGUIRecoveryEnabled')
FLAGS = ('globalFailureObserved', 'assertionFailureObserved', 'readFailureObserved', 'persistenceFailureObserved')
MODES = ('abort', 'replace', 'restart')
SHA = re.compile(r'[a-f0-9]{64}\Z')
UUID_SPELLING = re.compile(r'[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}\Z')
OLD_SHA = '3f27d94d0532b3c8a608bf99cb3208d3eab9e812c02f9c7eae80db67db7e9ecd'

class Refused(Exception):
    pass

def require(value, reason):
    if not value:
        raise Refused(reason)

def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def private(path, create=False):
    path = Path(path)
    if create:
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
    st = path.lstat()
    require(stat.S_ISDIR(st.st_mode) and st.st_uid == os.getuid() and st.st_mode & 0o077 == 0,
            'private-directory-refused')
    return path

def atomic(path, value):
    data = json.dumps(value, sort_keys=True, separators=(',', ':')).encode()
    require(len(data) <= 65536, 'receipt-budget-refused')
    private(path.parent)
    temporary = path.parent / ('pending-' + uuid.uuid4().hex)
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data); stream.flush(); os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if temporary.exists():
            temporary.unlink()

def bounded(arguments, timeout=8, limit=16384):
    process = subprocess.Popen(arguments, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, start_new_session=True)
    selector = selectors.DefaultSelector(); selector.register(process.stdout, selectors.EVENT_READ)
    output = bytearray(); deadline = time.monotonic() + timeout
    try:
        while selector.get_map():
            require(time.monotonic() < deadline, 'command-timeout')
            for key, _ in selector.select(min(.1, max(0, deadline - time.monotonic()))):
                data = os.read(key.fileobj.fileno(), 4096)
                if not data:
                    selector.unregister(key.fileobj)
                else:
                    output.extend(data); require(len(output) <= limit, 'command-output-budget')
        process.wait(timeout=max(.1, deadline - time.monotonic()))
        return process.returncode, bytes(output)
    finally:
        selector.close(); process.stdout.close()
        # This helper never wraps an app or bridge long-lived process.
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL); process.wait(timeout=1)

def hardware_guard():
    require(os.getuid() == 501, 'physical-host-refused')
    code, model = bounded(['/usr/sbin/sysctl', '-n', 'hw.model'], 4)
    require(code == 0 and model.startswith(b'VirtualMac'), 'physical-host-refused')
    code, interface = bounded(['/sbin/ifconfig', 'en0'], 4)
    require(code == 0 and re.search(rb'\bether ' + MAC.encode() + rb'\b', interface), 'different-guest-refused')
    code, owner = bounded(['/usr/bin/stat', '-f', '%Su', '/dev/console'], 4)
    require(code == 0 and owner.strip() == b'admin', 'guest-console-refused')

def same_lifetime(left, right):
    return left is not None and right is not None and all(left.get(key) == right.get(key)
        for key in ('pid', 'executable', 'sha256', 'startSeconds', 'startMicroseconds'))

def same_request(left, right):
    # Swift Codable UUID uses uppercase; compare the typed value, not spelling.
    if (type(left) is not str or type(right) is not str or
            UUID_SPELLING.fullmatch(left) is None or UUID_SPELLING.fullmatch(right) is None):
        return False
    try:
        return uuid.UUID(left) == uuid.UUID(right)
    except ValueError:
        return False

def app_ui_ready(fields, executable_sha, config, preferences):
    """Historical old schema is allowed only for its exact pinned executable."""
    old = config['artifacts']['old']['executableSHA256']
    new = config['artifacts']['new']['executableSHA256']
    require(old == OLD_SHA and executable_sha in (old, new), 'app-schema-identity-refused')
    display = config['wantedDisplay']
    expected = {KEYS[0]: {'present': True, 'value': True},
                KEYS[1]: {'present': True, 'value': display},
                KEYS[2]: {'present': True, 'value': False}}
    if type(fields) is not dict or preferences != expected:
        return False
    recovery_off = (fields.get('recoveryEnabled') is False or
                    (executable_sha == OLD_SHA and 'recoveryEnabled' not in fields))
    return (fields.get('sleepChecked') is True and fields.get('displayChecked') is display and
            recovery_off and fields.get('windowVisible') is True and
            fields.get('setupVisible') is False and fields.get('errorText') == '')

def validate_config(config):
    require(type(config) is dict and set(config) == {'schema', 'execution', 'vm', 'mac', 'run',
            'wantedDisplay', 'requireConnectedTunnel', 'artifacts', 'manifestSHA256'}, 'configuration-refused')
    require(type(config['schema']) is int and config['schema'] == 1 and config['vm'] == VM and config['mac'] == MAC and config['run'] == RUN,
            'configuration-refused')
    require(str(uuid.UUID(config['execution'])) == config['execution'], 'configuration-refused')
    require(type(config['wantedDisplay']) is bool and config['requireConnectedTunnel'] is True,
            'configuration-refused')
    require(SHA.fullmatch(config['manifestSHA256']) is not None, 'configuration-refused')
    require(type(config['artifacts']) is dict and set(config['artifacts']) == {'old', 'new', 'bridge', 'probe', 'operator'},
            'configuration-refused')
    for name, artifact in config['artifacts'].items():
        expected = {'file', 'sha256'} | ({'executableSHA256', 'infoSHA256'} if name in ('old', 'new') else set())
        require(type(artifact) is dict and set(artifact) == expected, 'configuration-refused')
        require(artifact['file'] == ('guest_operator.py' if name == 'operator' else
                name + ('.zip' if name in ('old', 'new') else '.bin')),
                'configuration-refused')
        require(all(type(artifact[key]) is str and SHA.fullmatch(artifact[key]) for key in expected - {'file'}),
                'configuration-refused')
    return config

def safe_extract(archive, destination):
    private(destination, create=True)
    with zipfile.ZipFile(archive) as package:
        entries = package.infolist(); require(len(entries) <= 4096, 'archive-refused')
        require(sum(item.file_size for item in entries) <= 128 * 1024 * 1024, 'archive-refused')
        names = set()
        for item in entries:
            path = PurePosixPath(item.filename)
            require(not path.is_absolute() and path.parts and path.parts[0] in ('NoSleep.app', '__MACOSX')
                    and '..' not in path.parts and '\\' not in item.filename and '\x00' not in item.filename
                    and item.filename not in names, 'archive-refused')
            names.add(item.filename)
            mode = item.external_attr >> 16
            require(not stat.S_ISLNK(mode), 'archive-refused')
            require(item.file_size <= 64 * 1024 * 1024, 'archive-refused')
        for item in entries:
            path = PurePosixPath(item.filename)
            if path.parts[0] != 'NoSleep.app':
                continue
            target = destination.joinpath(*path.parts)
            if item.is_dir():
                target.mkdir(mode=0o755, parents=True, exist_ok=True)
            else:
                target.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
                with package.open(item) as source, target.open('xb') as sink:
                    shutil.copyfileobj(source, sink, 65536)
                target.chmod(0o755 if item.external_attr >> 16 & 0o111 else 0o644)

def bridge_state(value, session, display, phase=None):
    require(type(value) is dict and value.get('session') == session and value.get('wantedDisplay') is display,
            'bridge-state-refused')
    require(all(value.get(flag) is False for flag in FLAGS), 'bridge-failure-latched')
    if phase is not None:
        require(value.get('phase') == phase, 'bridge-state-refused')
    require(value.get('sleepDisabled') is True, 'bridge-state-refused')
    return value

class GuestBindings:
    def __init__(self, config, execution_root):
        self.config = validate_config(config); self.root = private(execution_root)
        self.probe = self.root / 'assets/probe.bin'; self.bridge = self.root / 'assets/bridge.bin'
        self.install = self.root / 'install/NoSleep.app'
        self.actors = {}; self.bridges = {}; self.launch_times = {}; self.lock = None
        self.notify = None
        hardware_guard()
        require(digest(self.probe) == config['artifacts']['probe']['sha256'] and
                digest(self.bridge) == config['artifacts']['bridge']['sha256'], 'artifact-hash-refused')

    def guard(self):
        hardware_guard()

    def sample(self, pid=0):
        self.guard()
        require(digest(self.probe) == self.config['artifacts']['probe']['sha256'], 'artifact-hash-refused')
        code, raw = bounded([str(self.probe), '--snapshot', str(pid)], 8)
        require(code == 0, 'independent-probe-refused')
        value = json.loads(raw)
        require(value.get('schema') == 1 and type(value.get('sleepDisabled')) is bool,
                'independent-probe-refused')
        return value

    def preferences(self):
        self.guard()
        code, raw = bounded([str(self.probe), '--preferences'], 8)
        require(code == 0, 'preference-read-refused')
        values = json.loads(raw).get('keys')
        require(type(values) is dict and set(values) == set(KEYS), 'preference-read-refused')
        for value in values.values():
            require(type(value) is dict and type(value.get('present')) is bool and
                    set(value) == ({'present', 'value'} if value['present'] else {'present'}) and
                    (not value['present'] or type(value['value']) is bool), 'preference-read-refused')
        return values

    def write_preferences(self, values):
        self.guard()
        require(set(values) == set(KEYS), 'preference-write-refused')
        for key in KEYS:
            value = values[key]
            command = ['/usr/bin/defaults', 'write', DOMAIN, key, '-bool', 'true' if value.get('value') else 'false']
            if not value['present']:
                if not self.preferences()[key]['present']:
                    continue
                command = ['/usr/bin/defaults', 'delete', DOMAIN, key]
            code, _ = bounded(command, 8); require(code == 0, 'preference-write-refused')
        require(self.preferences() == values, 'preference-restoration-refused')

    def verify_bundle(self, app, kind):
        self.guard()
        artifact = self.config['artifacts'][kind]
        require(app.resolve().is_relative_to(self.root) and not any(p.is_symlink() for p in
                (app, app / 'Contents', app / 'Contents/MacOS', app / 'Contents/MacOS/NoSleep', app / 'Contents/Info.plist')),
                'bundle-refused')
        require(digest(app / 'Contents/MacOS/NoSleep') == artifact['executableSHA256'] and
                digest(app / 'Contents/Info.plist') == artifact['infoSHA256'], 'bundle-hash-refused')
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        require(info.get('CFBundleIdentifier') == DOMAIN and info.get('CFBundleExecutable') == 'NoSleep', 'bundle-refused')
        code, _ = bounded(['/usr/bin/codesign', '--verify', '--strict', str(app)], 8)
        require(code == 0, 'bundle-signature-refused')

    def install_kind(self, kind):
        self.guard()
        require(self.sample()['noSleepPIDs'] == [], 'competing-app-refused')
        source = self.root / (kind + '/NoSleep.app'); self.verify_bundle(source, kind)
        private(self.install.parent, create=True)
        replacement = self.install.parent / ('replacement-' + uuid.uuid4().hex + '.app')
        shutil.copytree(source, replacement); self.verify_bundle(replacement, kind)
        if self.install.exists():
            previous = self.root / ('retired-' + uuid.uuid4().hex + '.app')
            os.replace(self.install, previous)
        os.replace(replacement, self.install); self.verify_bundle(self.install, kind)

    def launch(self, kind):
        self.guard(); self.verify_bundle(self.install, kind)
        require(self.notify is not None, 'journal-required')
        require(self.sample()['noSleepPIDs'] == [], 'competing-app-refused')
        started = time.time()
        process = subprocess.Popen([str(self.install / 'Contents/MacOS/NoSleep')], stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        self.actors[process.pid] = process; self.launch_times[process.pid] = started
        self.notify('app', {'pid':process.pid, 'executable':str(self.install/'Contents/MacOS/NoSleep'),
                           'sha256':self.config['artifacts'][kind]['executableSHA256']})
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            require(process.poll() is None, 'app-start-refused')
            value = self.sample(process.pid); identity = value['process']
            if identity is not None:
                require(identity['executable'] == str(self.install / 'Contents/MacOS/NoSleep') and
                        identity['sha256'] == self.config['artifacts'][kind]['executableSHA256'], 'app-identity-refused')
                return identity
            time.sleep(.1)
        raise Refused('app-start-timeout')

    def ready(self, identity, display):
        deadline = time.monotonic() + 15
        ui = Path('/Users/admin/Library/Application Support/NoSleep/ui.json')
        while time.monotonic() < deadline:
            value = self.sample(identity['pid']); require(same_lifetime(value['process'], identity), 'app-lifetime-refused')
            require(value['noSleepPIDs'] == [identity['pid']], 'competing-app-refused')
            if (value['sleepDisabled'] and value['idleOn'] and value['displayOn'] is display and
                    ui.is_file() and not ui.is_symlink() and ui.stat().st_size <= 32768 and
                    ui.stat().st_mtime >= self.launch_times[identity['pid']]):
                fields = json.loads(ui.read_bytes())
                if app_ui_ready(fields, identity['sha256'], self.config, self.preferences()):
                    return value
            time.sleep(.1)
        raise Refused('app-readiness-timeout')

    def signal(self, identity, value):
        self.guard()
        require(value in (signal.SIGSTOP, signal.SIGCONT, signal.SIGKILL), 'signal-refused')
        require(Path(identity['executable']).is_relative_to(self.root) and
                identity['executable'] == str(self.install / 'Contents/MacOS/NoSleep'), 'signal-refused')
        sample = self.sample(identity['pid'])
        require(same_lifetime(sample['process'], identity), 'app-lifetime-refused')
        os.kill(identity['pid'], value)

    def wait_status(self, identity, stopped):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            value = self.sample(identity['pid'])
            require(same_lifetime(value['process'], identity), 'app-lifetime-refused')
            if (value['process']['status'] == 4) is stopped:
                return value
            time.sleep(.05)
        raise Refused('app-signal-timeout')

    def absent(self, identity):
        process = self.actors.get(identity['pid'])
        if process is not None:
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                raise Refused('app-reap-timeout') from None
        require(self.sample(identity['pid'])['process'] is None, 'old-still-present')

    def start_bridge(self, old, display, case):
        self.guard()
        require(self.notify is not None, 'journal-required')
        require(digest(self.bridge) == self.config['artifacts']['bridge']['sha256'], 'artifact-hash-refused')
        directory = private(self.root / ('bridge-' + case), create=True)
        require(not any(directory.iterdir()), 'bridge-checkpoint-exists')
        session = str(uuid.uuid4())
        arguments = [str(self.bridge), '--hold', '--old-pid', str(old['pid']), '--old-executable', old['executable'],
            '--old-sha256', old['sha256'], '--new-executable', str(self.install / 'Contents/MacOS/NoSleep'),
            '--new-sha256', self.config['artifacts']['new']['executableSHA256'], '--state-dir', str(directory),
            '--session', session, '--wanted-display', '1' if display else '0']
        process = subprocess.Popen(arguments, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL, start_new_session=True)
        actor = {'pid': process.pid, 'directory': str(directory), 'session': session, 'wantedDisplay': display}
        self.bridges[process.pid] = process
        self.notify('bridge', actor)
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            require(process.poll() is None, 'bridge-start-refused')
            if (directory / 'state.json').exists():
                identity = self.sample(process.pid)['process']
                if identity is not None:
                    actor['identity'] = identity; self.bridge_held(actor); return actor
            time.sleep(.1)
        raise Refused('bridge-start-timeout')

    def state(self, actor):
        path = Path(actor['directory']) / 'state.json'
        require(path.is_file() and not path.is_symlink() and path.stat().st_size <= 8192, 'bridge-state-refused')
        return bridge_state(json.loads(path.read_bytes()), actor['session'], actor['wantedDisplay'])

    def events(self, actor):
        path = Path(actor['directory']) / 'events.jsonl'
        require(path.is_file() and not path.is_symlink() and path.stat().st_size <= 65536, 'bridge-events-refused')
        events = [json.loads(line) for line in path.read_bytes().splitlines()]
        require(events and all(event.get('session') == actor['session'] and
                not any(event.get(flag) is not False for flag in ('globalFailure','assertionFailure','readFailure','persistenceFailure'))
                for event in events), 'bridge-failure-latched')
        return events

    def bridge_held(self, actor):
        self.guard(); state = self.state(actor); require(state['phase'] == 'holding', 'bridge-state-refused')
        require(time.time() - (Path(actor['directory']) / 'state.json').stat().st_mtime <= 3, 'bridge-state-stale')
        require(state['ownAssertionsOn'] is True and self.bridges[actor['pid']].poll() is None, 'bridge-not-held')
        value = self.sample(actor['pid'])
        require(same_lifetime(value['process'], actor['identity']) and value['process']['sha256'] ==
                self.config['artifacts']['bridge']['sha256'] and value['sleepDisabled'] and value['idleOn'] and value['displayOn'],
                'bridge-not-held')
        self.events(actor)

    def request(self, actor, action, pid=None, expect_refusal=False):
        self.bridge_held(actor)
        request = str(uuid.uuid4()); payload = {'session': actor['session'], 'request': request, 'action': action}
        if pid is not None:
            payload['pid'] = pid
        atomic(Path(actor['directory']) / 'command.json', payload)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            state = self.state(actor)
            if same_request(state.get('request'), request):
                if expect_refusal and state['lastCommand'] != 'prepared':
                    require(state['phase'] == 'holding' and state['lastCommand'] in ('targetProofFailed','oldNotResumed'), 'refusal-proof-refused')
                    self.bridge_held(actor); return state
                if not expect_refusal and state['phase'].startswith('released-to-'):
                    try:
                        code = self.bridges[actor['pid']].wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        raise Refused('bridge-terminal-timeout') from None
                    require(code == 0 and state['ownAssertionsOn'] is False, 'bridge-terminal-refused')
                    events = self.events(actor)
                    require(any(item.get('kind') == 'released' and same_request(item.get('request'), request) for item in events), 'bridge-events-refused')
                    require(self.sample(actor['pid'])['process'] is None, 'bridge-terminal-refused')
                    return state
            time.sleep(.05)
        raise Refused('bridge-observation-timeout')

    def nonce(self):
        # Data-plane read only in the already connected disposable tunnel.
        import secrets
        import urllib.request
        self.guard()
        code, route = bounded(['/sbin/route', '-n', 'get', '192.0.2.1'], 4)
        require(code == 0 and re.search(rb'interface:\s+utun[0-9]+', route), 'tunnel-route-refused')
        nonce = secrets.token_hex(32)
        request = urllib.request.Request('http://192.0.2.1:8080/proof?run=' + RUN + '&nonce=' + nonce,
                                         headers={'Cache-Control':'no-cache'})
        with urllib.request.urlopen(request, timeout=4) as response:
            body = response.read(1025)
            require(response.status == 200 and len(body) <= 1024 and response.headers.get('Cache-Control') == 'no-store', 'nonce-refused')
        require(json.loads(body) == {'run':RUN,'nonce':nonce}, 'nonce-refused')
        return {'matched':True,'runMatched':True,'tunnelRoute':True,'challengeSHA256':hashlib.sha256(nonce.encode()).hexdigest()}

    def restore_global(self, prior):
        self.guard(); require(self.sample()['noSleepPIDs'] == [] and self.sample()['bridgePIDs'] == [], 'actors-still-present')
        code, _ = bounded(['/usr/bin/sudo','-n','/usr/bin/pmset','-a','disablesleep','1' if prior else '0'], 8)
        require(code == 0, 'global-restoration-refused')
        deadline = time.monotonic() + 6
        while time.monotonic() < deadline:
            require(self.sample()['sleepDisabled'] is prior, 'global-restoration-refused')
            time.sleep(.2)

class HandoffRunner:
    def __init__(self, bindings, config, checkpoint):
        self.b = bindings; self.config = config; self.checkpoint = checkpoint
        self.receipt = {'schema':1,'execution':config['execution'],'scope':'full-owned-VM-old-new-handoff',
            'caseReceipts':[],'result':'running','mainActions':0,'vpnAuthenticationActions':0,'ciscoActions':0,
            'preferenceRestored':False,'priorGlobalRestored':False,'fullHandoffProven':False}
        self.active = None; self.current = None; self.prior = None; self.backup = None
        self.b.notify = self.actor_started

    def actor_started(self, kind, identity):
        if kind == 'bridge':
            self.active = identity
        else:
            self.current = identity
        self.save(kind + '-spawned-checkpoint')

    def save(self, phase):
        self.receipt['phase'] = phase
        self.receipt['updatedUptime'] = time.monotonic()
        self.receipt['activeBridge'] = self.active
        self.receipt['currentApp'] = self.current
        self.checkpoint(self.receipt)

    def fresh_intent(self):
        return {KEYS[0]:{'present':True,'value':True},KEYS[1]:{'present':True,'value':self.config['wantedDisplay']},
                KEYS[2]:{'present':True,'value':False}}

    def run_case(self, case):
        require(case in MODES, 'case-refused')
        self.b.write_preferences(self.fresh_intent()); self.b.install_kind('old')
        self.current = old = self.b.launch('old'); self.save(case + '-old-launched')
        self.b.ready(old, self.config['wantedDisplay']); before = self.b.nonce()
        self.active = self.b.start_bridge(old, self.config['wantedDisplay'], case); self.save(case + '-bridge-holding')
        self.b.bridge_held(self.active); self.b.signal(old, signal.SIGSTOP)
        self.b.wait_status(old, True); self.b.bridge_held(self.active); self.save(case + '-old-stopped')
        if case == 'abort':
            self.b.signal(old, signal.SIGCONT); self.b.wait_status(old, False); self.b.ready(old, self.config['wantedDisplay'])
            final = self.b.request(self.active, 'abort-old-resumed')
            require(final['phase'] == 'released-to-old', 'bridge-release-refused')
            target = old
        else:
            self.b.bridge_held(self.active); self.b.signal(old, signal.SIGKILL); self.b.absent(old)
            self.current = None; self.save(case + '-old-terminal')
            self.b.bridge_held(self.active); self.b.install_kind('new')
            self.current = target = self.b.launch('new'); self.save(case + '-new-launched')
            if case == 'restart':
                # Real final new app, deliberately stopped before release: no fake executable.
                self.b.signal(target, signal.SIGSTOP); self.b.wait_status(target, True)
                self.b.request(self.active, 'release-new', target['pid'], expect_refusal=True)
                self.b.bridge_held(self.active); self.b.signal(target, signal.SIGKILL); self.b.absent(target)
                self.current = None; self.b.install_kind('old')
                self.current = target = self.b.launch('old'); self.save(case + '-old-restarted')
                self.b.ready(target, self.config['wantedDisplay'])
                self.b.request(self.active, 'abort-old-resumed', expect_refusal=True)
                final = self.b.request(self.active, 'rollback-old-restarted', target['pid'])
                require(final['phase'] == 'released-to-restarted-old', 'bridge-release-refused')
            else:
                self.b.ready(target, self.config['wantedDisplay'])
                final = self.b.request(self.active, 'release-new', target['pid'])
                require(final['phase'] == 'released-to-new', 'bridge-release-refused')
        self.active = None
        self.b.ready(target, self.config['wantedDisplay'])
        require(self.b.preferences() == self.fresh_intent(), 'intent-not-preserved')
        after = self.b.nonce()
        self.receipt['caseReceipts'].append({'case':case,'oldIdentity':old,'targetIdentity':target,
            'finalPhase':final['phase'],'pinnedDisplayPreserved':True,'recoveryOFF':True,
            'freshIndependentTargetPowerProof':True,'normalDurableBridgeExit':True,
            'beforeNonce':before,'afterNonce':after,'fullOldNewCaseProven':True})
        self.save(case + '-passed')
        self.b.signal(target, signal.SIGKILL); self.b.absent(target); self.current = None

    def execute(self):
        self.b.guard()
        initial = self.b.sample()
        require(initial['noSleepPIDs'] == [] and initial['bridgePIDs'] == [], 'competing-actor-refused')
        self.prior = initial['sleepDisabled']; self.backup = self.b.preferences()
        self.receipt['priorGlobal'] = self.prior; self.receipt['preferenceBackup'] = self.backup
        self.save('backup-durable')
        try:
            for case in MODES:
                self.run_case(case)
            self.receipt['result'] = 'passed'
        except Exception as failure:
            self.receipt['result'] = 'failed'; self.receipt['reason'] = str(failure) if isinstance(failure, Refused) else 'bounded-operator-error'
        finally:
            if self.active is not None:
                # Never stop a live bridge after uncertainty/timeout. Inspect exact checkpoint first.
                self.receipt['restorationDeferred'] = True; self.save('failed-holding')
            else:
                if self.current is not None:
                    if 'startSeconds' not in self.current or 'startMicroseconds' not in self.current:
                        self.receipt['restorationDeferred'] = True
                        self.save('failed-app-identity-unconfirmed')
                        return self.receipt
                    self.b.signal(self.current, signal.SIGKILL); self.b.absent(self.current); self.current = None
                self.b.write_preferences(self.backup); self.b.restore_global(self.prior)
                self.receipt['preferenceRestored'] = self.b.preferences() == self.backup
                self.receipt['priorGlobalRestored'] = self.b.sample()['sleepDisabled'] is self.prior
                self.receipt['fullHandoffProven'] = self.receipt['result'] == 'passed' and len(self.receipt['caseReceipts']) == 3
                self.save('terminal')
        return self.receipt

def stage(config, config_path):
    hardware_guard(); validate_config(config)
    root = private(ROOT, create=True); execution = root / 'runs' / config['execution']
    require(not execution.exists(), 'existing-checkpoint-refused'); private(execution, create=True)
    assets = private(execution / 'assets', create=True)
    share = config_path.parent
    for name, item in config['artifacts'].items():
        source = share / item['file']
        require(source.is_file() and not source.is_symlink() and source.stat().st_size <= 64*1024*1024 and digest(source) == item['sha256'], 'artifact-hash-refused')
        target = assets / item['file']; shutil.copyfile(source,target); target.chmod(0o600 if name in ('old','new','operator') else 0o700)
        require(digest(target) == item['sha256'], 'artifact-hash-refused')
    for kind in ('old','new'):
        safe_extract(assets / (kind + '.zip'), execution / kind)
    atomic(execution / 'configuration.json', config)
    return execution

def inspection(bindings, config, receipt):
    value = {'schema':1,'inspectionOnly':True,'execution':config['execution'],'receipt':receipt,
             'globalSnapshot':bindings.sample(), 'preferences':bindings.preferences()}
    for name, key in (('Operator','operatorIdentity'), ('Bridge','activeBridge'), ('App','currentApp')):
        actor = receipt.get(key)
        expected = actor.get('identity') if name == 'Bridge' and actor else actor
        snapshot = bindings.sample(actor['pid']) if actor else None
        current = snapshot['process'] if snapshot else None
        provisional = actor is not None and (expected is None or any(field not in expected for field in
            ('pid','executable','sha256','startSeconds','startMicroseconds')))
        value['current' + name] = current
        value['current' + name + 'Snapshot'] = snapshot
        value['current' + name + 'CheckpointProvisional'] = provisional
        value['current' + name + 'LifetimeMatches'] = bool(expected and not provisional and
                                                        same_lifetime(current, expected))
    return value

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--execute', action='store_true'); parser.add_argument('--inspect', action='store_true')
    parser.add_argument('--config', required=True); parser.add_argument('--config-sha256', required=True)
    args = parser.parse_args()
    require(args.execute != args.inspect, 'execution-option-refused'); hardware_guard()
    config_path = Path(args.config)
    require(config_path.is_relative_to(Path('/Volumes/My Shared Files')) and not config_path.is_symlink() and
            config_path.stat().st_size <= 32768 and SHA.fullmatch(args.config_sha256) and digest(config_path)==args.config_sha256, 'configuration-hash-refused')
    config = validate_config(json.loads(config_path.read_bytes()))
    require(digest(Path(__file__)) == config['artifacts']['operator']['sha256'], 'operator-source-refused')
    execution = ROOT / 'runs' / config['execution']
    if args.inspect:
        private(execution); bindings = GuestBindings(config,execution)
        path = execution/'receipt.json'; require(path.is_file() and not path.is_symlink() and path.stat().st_size<=65536,'checkpoint-refused')
        receipt=json.loads(path.read_bytes())
        print(json.dumps(inspection(bindings,config,receipt)))
        return
    private(ROOT,create=True)
    lock_path=ROOT/'operator.lock'; fd=os.open(lock_path,os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW,0o600)
    require(os.fstat(fd).st_uid==os.getuid() and os.fstat(fd).st_mode & 0o077==0,'operator-lock-refused')
    fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
    execution=stage(config,config_path); bindings=GuestBindings(config,execution)
    runner=HandoffRunner(bindings,config,lambda value:atomic(execution/'receipt.json',value))
    runner.receipt['operatorIdentity']=bindings.sample(os.getpid())['process']
    result=runner.execute(); print(json.dumps(result)); raise SystemExit(0 if result['fullHandoffProven'] else 1)

if __name__=='__main__':
    try:
        main()
    except Refused as failure:
        print(json.dumps({'schema':1,'result':'refused','reason':str(failure),'mainActions':0})); raise SystemExit(1)
    except Exception:
        print(json.dumps({'schema':1,'result':'failed','reason':'bounded-operator-error','mainActions':0})); raise SystemExit(1)
