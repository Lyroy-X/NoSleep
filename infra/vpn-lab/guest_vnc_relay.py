#!/usr/bin/env python3
"""Loopback-only RFB -> owned guest's existing Screen Sharing, over virtio RPC.

No host screen/clipboard, IP guest route, SSH, remote-management reconfiguration
or raw wire output. The guest model/MAC is verified before each connection.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import selectors
import shlex
import signal
import socket
import subprocess
import threading
import time
import uuid

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("guest", HERE / "guest_command.py")
guest = importlib.util.module_from_spec(spec); spec.loader.exec_module(guest)
SUPERVISOR = (HERE / 'guest_rfb_supervisor.py').read_text()
SUPERVISOR_SHA = hashlib.sha256(SUPERVISOR.encode()).hexdigest()


def remote_command(mode, action):
    return shlex.join(['/usr/bin/python3','-c',SUPERVISOR,mode,action,SUPERVISOR_SHA])+'\n'


def durable_action(path, value, create=False):
    if create:
        fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
        with os.fdopen(fd,'w') as f:
            json.dump(value,f);f.write('\n');f.flush();os.fsync(f.fileno())
        fd=os.open(path.parent,os.O_RDONLY)
        try:os.fsync(fd)
        finally:os.close(fd)
        return
    tmp=path.with_name(path.name+'.tmp')
    with open(tmp,'x') as f:
        os.fchmod(f.fileno(),0o600)
        json.dump(value,f);f.write('\n');f.flush();os.fsync(f.fileno())
    os.replace(tmp,path)
    fd=os.open(path.parent,os.O_RDONLY)
    try:os.fsync(fd)
    finally:os.close(fd)


def stop_remote_action(action):
    code,out=guest.run(remote_command('stop',action),timeout=15,output_limit=4096)
    if code:return {'remoteCleanupConfirmed':False,'fixedFailure':'guestStopRefused'}
    try:value=json.loads(out)
    except ValueError:return {'remoteCleanupConfirmed':False,'fixedFailure':'guestStopMetadataInvalid'}
    if value.get('ownedAction') is not True or value.get('actualProcessAbsent') is not True:
        return {'remoteCleanupConfirmed':False,'fixedFailure':'guestActualAbsenceNotProven'}
    calls=value.get('signalCalls')
    if type(calls) is not int or calls not in (0,1):
        return {'remoteCleanupConfirmed':False,'fixedFailure':'guestSignalBudgetMetadataInvalid'}
    if value.get('socketOwnerGone') is not True or value.get('durableClosedMarker') is not True:
        return {'remoteCleanupConfirmed':False,'fixedFailure':'guestClosedDurabilityNotProven',
                'actualRemoteProcessAbsent':True,'remoteStopSignalCalls':calls,
                'durableRemoteClosedMarker':value.get('durableClosedMarker') is True}
    return {'remoteCleanupConfirmed':True,'actualRemoteProcessAbsent':True,
            'remoteStopSignalCalls':calls,'durableRemoteClosedMarker':True}


def remote_ready(action,timeout=3):
    code,out=guest.run(remote_command('status',action),timeout=timeout,output_limit=4096)
    if code:return None
    try:value=json.loads(out)
    except ValueError:return None
    if value.get('ownedAction') is True and value.get('exactLifetimePresent') is True and value.get('phase')=='streaming':
        return value
    return None


def wait_remote_ready(action,process,stopping):
    deadline=time.monotonic()+10
    while time.monotonic()<deadline and process.poll() is None and not stopping():
        value=remote_ready(action,timeout=min(3,max(1,deadline-time.monotonic())))
        if value is not None:return value
        time.sleep(.05)
    raise ValueError('owned remote RFB readiness not proven')


def relay_stream(client,process,stopping=lambda:False,ttl=10800,observe_queues=None):
    """Credit-limited opaque pipe/socket forwarding with bounded EOF drain."""
    selector=selectors.DefaultSelector()
    inputs=(client,process.stdout);outputs=(process.stdin,client)
    queues=(bytearray(),bytearray());cap=131072
    for endpoint in (client,process.stdin,process.stdout):os.set_blocking(endpoint.fileno(),False)
    deadline=time.monotonic()+ttl;drain=None
    try:
        while not stopping() and time.monotonic()<deadline:
            if drain is not None and (time.monotonic()>=drain or not any(queues)):return 'eof-drained'
            desired={}
            if drain is None:
                for n,endpoint in enumerate(inputs):
                    if len(queues[n])<cap:desired[endpoint]=selectors.EVENT_READ
            for n,queue in enumerate(queues):
                if len(queue)>cap:raise ValueError('guest RFB byte queue exceeds budget')
                if queue:desired[outputs[n]]=desired.get(outputs[n],0)|selectors.EVENT_WRITE
            for key in list(selector.get_map().values()):
                if key.fileobj not in desired:selector.unregister(key.fileobj)
            for endpoint,events in desired.items():
                try:selector.modify(endpoint,events)
                except KeyError:selector.register(endpoint,events)
            for key,events in selector.select(min(.2,max(0,deadline-time.monotonic()))):
                endpoint=key.fileobj
                if events&selectors.EVENT_READ:
                    n=0 if endpoint is client else 1
                    credit=cap-len(queues[n])
                    if credit<=0:continue
                    try:data=os.read(endpoint.fileno(),min(65536,credit))
                    except BlockingIOError:
                        time.sleep(.001);continue
                    if not data:drain=min(deadline,time.monotonic()+2)
                    else:
                        queues[n].extend(data)
                        if len(queues[n])>cap:raise ValueError('guest RFB byte queue exceeds budget')
                        if observe_queues:observe_queues(tuple(len(q) for q in queues))
                if events&selectors.EVENT_WRITE:
                    n=1 if endpoint is client else 0
                    try:written=os.write(endpoint.fileno(),queues[n][:65536])
                    except BlockingIOError:
                        time.sleep(.001);continue
                    del queues[n][:written]
        return 'stopped' if stopping() else 'absolute-expiry'
    finally:selector.close()


def forward(client, stopping=lambda:False):
    if stopping():client.close();return False
    process = None
    action=str(uuid.uuid4())
    directory=guest.ROOT/'screen-sharing-actions'
    if directory.is_symlink():client.close();return False
    directory.mkdir(mode=0o700,exist_ok=True)
    if directory.stat().st_uid!=os.getuid() or directory.stat().st_mode&0o077:
        client.close();return False
    path=directory/(action+'.json')
    state={'schema':1,'action':action,'supervisorSourceSHA256':SUPERVISOR_SHA,
           'remoteMarker':'/Users/admin/NoSleepLab/screen-sharing-rfb/'+action+'.json',
           'remoteCleanupConfirmed':False,'phase':'intent','wireBytesPersisted':False}
    try:
        code, _ = guest.run("test \"$(/usr/bin/stat -f '%Su' /dev/console)\" = admin\n", timeout=15)
        if code:
            return
        command, env, guard = guest.vsock_base()
        if stopping():return False
        durable_action(path,state,create=True)
        process = subprocess.Popen(command + ["/bin/bash", "-c", guard + 'exec '+remote_command('run',action)],
                                   env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL, start_new_session=True)
        state.update({'phase':'streaming','hostRPCPID':process.pid})
        durable_action(path,state)
        readiness=wait_remote_ready(action,process,stopping)
        state['remoteReadiness']=readiness;durable_action(path,state)
        state['hostStreamClosedReason']=relay_stream(client,process,stopping)
    except (OSError, ValueError, subprocess.SubprocessError, TimeoutError):
        pass  # No byte or credential is emitted to logs.
    finally:
        client.close()
        if process:
            try:
                state['phase']='remote-stop-intent';durable_action(path,state)
                state.update(stop_remote_action(action))
            except Exception:
                state.update({'remoteCleanupConfirmed':False,'fixedFailure':'remoteStopUncertain'})
            # This is only the owned host RPC child. Its cancellation is not
            # used as evidence that the remote socket owner disappeared.
            if process.poll() is None:
                process.terminate()
                try:process.wait(timeout=3)
                except subprocess.TimeoutExpired:process.kill();process.wait(timeout=3)
            else:process.wait(timeout=3)
            state['hostRPCReaped']=True;state['phase']='closed' if state['remoteCleanupConfirmed'] else 'cleanup-uncertain'
            durable_action(path,state)
    return state['remoteCleanupConfirmed']


class SessionWorkers:
    """Sticky admission gate and bounded graceful cleanup of the active stream."""
    def __init__(self):
        self.stopping=threading.Event()
        self.lock=threading.Lock()
        self.capacity=threading.BoundedSemaphore(1)
        self.workers=set()

    def stop(self):self.stopping.set()

    def admit(self,client,target=forward):
        with self.lock:
            # accept() may have returned after another stream became unknown.
            if self.stopping.is_set() or not self.capacity.acquire(blocking=False):
                client.close();return False
            worker=threading.Thread(target=self.run,args=(client,target),daemon=False)
            self.workers.add(worker);worker.start()
            return True

    def run(self,client,target):
        try:
            if self.stopping.is_set():client.close()
            elif not target(client,self.stopping.is_set):self.stop()
        except Exception:
            client.close()
            self.stop()  # No new stream after an unknown cleanup/persist result.
        finally:
            with self.lock:self.workers.discard(threading.current_thread())
            self.capacity.release()

    def shutdown(self,timeout=30):
        self.stop();end=time.monotonic()+timeout
        with self.lock:workers=list(self.workers)
        for worker in workers:worker.join(timeout=max(0,end-time.monotonic()))
        return not any(worker.is_alive() for worker in workers)


def main():
    parser = argparse.ArgumentParser()
    parser.parse_args()
    code, _ = guest.run("test \"$(/usr/bin/stat -f '%Su' /dev/console)\" = admin\n", timeout=15)
    if code:
        raise ValueError("owned guest console is not admin")
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0)); listener.listen(4); listener.settimeout(1)
    runtime = json.loads((guest.ROOT / "guest-runtime.json").read_text())
    password = guest.ROOT / "guest-admin-password.txt"
    password.write_text("admin\n"); password.chmod(0o600)
    state = {"host": "127.0.0.1", "port": listener.getsockname()[1], "pid": os.getpid(),
             "name": guest.NAME, "mode": "owned-guest-screen-sharing",
             "runtimePID": runtime["pid"], "mac": runtime["mac"], "username": "admin",
             "passwordFile": str(password), "transport": "owned-virtio-vsock"}
    state.update({'supervisorSourceSHA256':SUPERVISOR_SHA,'privateRemoteMarkerLifecycle':True})
    path = guest.ROOT / "guest-screen-sharing.json"
    path.write_text(json.dumps(state, indent=2)); path.chmod(0o600)
    print(json.dumps({"ownedGuestScreenSharingReady": True, "loopbackPort": state["port"],
                      "privateState": str(path)}), flush=True)
    workers=SessionWorkers()

    def stop(*_):
        workers.stop()

    signal.signal(signal.SIGTERM, stop); signal.signal(signal.SIGINT, stop)

    deadline = time.monotonic() + 3 * 3600
    try:
        while not workers.stopping.is_set() and time.monotonic() < deadline:
            try:
                client, _ = listener.accept()
            except socket.timeout:
                continue
            workers.admit(client)
    finally:
        listener.close()
        complete=workers.shutdown()
        print(json.dumps({'ownedGuestScreenSharingShutdownComplete':complete,
                          'newConnectionsAllowed':False}),flush=True)
        if not complete:
            # Non-daemon workers remain alive for their existing cleanup; do
            # not tear them down or imply remote absence on a join timeout.
            raise RuntimeError('owned RFB cleanup remains unresolved')


if __name__ == "__main__":
    main()
