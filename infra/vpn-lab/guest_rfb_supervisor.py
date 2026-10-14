#!/usr/bin/env python3
"""One finite owned guest RFB stream; stdout is opaque wire data in run mode.

No persistent service, framebuffer parser, credentials, clipboard or GUI API.
Each stream has a private action marker and an explicit lifetime-guarded stop.
"""
import argparse
import ctypes
from contextlib import contextmanager
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import signal
import socket
import stat
import subprocess
import sys
import time

ROOT = Path('/Users/admin/NoSleepLab/screen-sharing-rfb')
MAC = '42:35:8c:14:fd:0c'
TTL = 10800
QUEUE_LIMIT = 131072
UUID_RE = re.compile(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}')


def require(value):
    if not value: raise ValueError('owned RFB lifecycle guard refused')


def guard_guest():
    require(os.getuid() == 501)
    model = subprocess.check_output(['/usr/sbin/sysctl', '-n', 'hw.model'], timeout=3).decode().strip()
    owner = subprocess.check_output(['/usr/bin/stat', '-f', '%Su', '/dev/console'], timeout=3).decode().strip()
    network = subprocess.check_output(['/sbin/ifconfig', 'en0'], timeout=3).decode()
    require(model.startswith('VirtualMac') and owner == 'admin' and re.search(r'\bether '+re.escape(MAC)+r'\b', network))


class BSDInfo(ctypes.Structure):
    _fields_ = [(name, ctypes.c_uint32) for name in
                ('flags','status','xstatus','pid','ppid','uid','gid','ruid','rgid','svuid','svgid','rfu')]
    _fields_ += [('comm',ctypes.c_char*16),('name',ctypes.c_char*32)]
    _fields_ += [(name,ctypes.c_uint32) for name in ('nfiles','pgid','pjobc','tdev','tpgid','nice')]
    _fields_ += [('startSeconds',ctypes.c_uint64),('startMicroseconds',ctypes.c_uint64)]


def process_identity(pid):
    lib = ctypes.CDLL('/usr/lib/libproc.dylib',use_errno=True)
    lib.proc_pidinfo.argtypes=[ctypes.c_int,ctypes.c_int,ctypes.c_uint64,ctypes.c_void_p,ctypes.c_int]
    lib.proc_pidpath.argtypes=[ctypes.c_int,ctypes.c_void_p,ctypes.c_uint32]
    def sample():
        value=BSDInfo()
        ctypes.set_errno(0)
        n=lib.proc_pidinfo(pid,3,0,ctypes.byref(value),ctypes.sizeof(value))
        if n==ctypes.sizeof(value):return value
        if n==0 and ctypes.get_errno()==errno.ESRCH:return None
        raise ValueError('owned RFB identity read failed')
    info=sample()
    if info is None:return None
    buf=ctypes.create_string_buffer(4096)
    require(lib.proc_pidpath(pid,buf,len(buf))>0)
    executable=Path(os.fsdecode(buf.value)).resolve(strict=True)
    result=subprocess.run(['/bin/ps','-ww','-p',str(pid),'-o','command='],capture_output=True,timeout=3)
    require(result.returncode==0 and len(result.stdout)<=65536)
    sha=hashlib.sha256(executable.read_bytes()).hexdigest()
    last=sample()
    require(last is not None and last.pid==info.pid and last.startSeconds==info.startSeconds and last.startMicroseconds==info.startMicroseconds)
    return {'pid':pid,'uid':info.uid,'parentPID':info.ppid,
            'startSeconds':info.startSeconds,'startMicroseconds':info.startMicroseconds,
            'executable':str(executable),'executableSHA256':sha,
            'argvSHA256':hashlib.sha256(result.stdout.strip()).hexdigest()}


def directory(path):
    require(path.parent.is_dir() and not path.parent.is_symlink() and path.parent.stat().st_uid==os.getuid())
    require(not path.is_symlink())
    path.mkdir(mode=0o700,exist_ok=True)
    st=path.stat()
    require(path.is_dir() and st.st_uid==os.getuid() and stat.S_IMODE(st.st_mode)==0o700)


def fsync_dir(path):
    fd=os.open(path,os.O_RDONLY)
    try:os.fsync(fd)
    finally:os.close(fd)


class Marker:
    def __init__(self,root,action):
        require(UUID_RE.fullmatch(action))
        self.path=root/(action+'.json')

    @contextmanager
    def locked(self):
        fd=os.open(self.path.with_suffix('.lock'),os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW,0o600)
        try:
            st=os.fstat(fd)
            require(stat.S_ISREG(st.st_mode) and st.st_uid==os.getuid() and stat.S_IMODE(st.st_mode)==0o600)
            end=time.monotonic()+2
            while True:
                try:fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB);break
                except BlockingIOError:
                    if time.monotonic()>=end:raise TimeoutError('owned marker lock unavailable')
                    time.sleep(.02)
            yield
        finally:
            os.close(fd)

    def create(self,value):
        directory(self.path.parent)
        fd=os.open(self.path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
        with os.fdopen(fd,'w') as f:
            json.dump(value,f);f.write('\n');f.flush();os.fsync(f.fileno())
        fsync_dir(self.path.parent)

    def read(self):
        root=self.path.parent
        require(root.is_dir() and not root.is_symlink() and root.stat().st_uid==os.getuid() and stat.S_IMODE(root.stat().st_mode)==0o700)
        fd=os.open(self.path,os.O_RDONLY|os.O_NOFOLLOW)
        with os.fdopen(fd) as f:
            st=os.fstat(f.fileno())
            require(stat.S_ISREG(st.st_mode) and st.st_uid==os.getuid() and stat.S_IMODE(st.st_mode)==0o600 and st.st_size<=8192)
            return json.load(f)

    def save(self,value):
        with self.locked():
            current=self.read()
            value=dict(value)
            if current.get('stopRequested',False):
                value['stopRequested']=True;value['stopSignalCalls']=current['stopSignalCalls']
            self.save_locked(value)

    def save_locked(self,value):
        tmp=self.path.with_name(self.path.name+'.'+str(os.getpid())+'.tmp')
        fd=os.open(tmp,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
        try:
            with os.fdopen(fd,'w') as f:
                json.dump(value,f);f.write('\n');f.flush();os.fsync(f.fileno())
            os.replace(tmp,self.path);fsync_dir(self.path.parent)
        finally:
            tmp.unlink(missing_ok=True)

    def claim_stop_once(self,expected):
        with self.locked():
            state=self.read()
            require(state['identity']==expected and not state.get('stopRequested',False))
            require(state.get('phase')!='closed')
            state['stopRequested']=True;state['stopSignalCalls']=1
            self.save_locked(state)
            return state

    def closed_durability_barrier(self):
        value=self.read()
        require(value.get('phase')=='closed' and value.get('socketClosed') is True)
        fd=os.open(self.path,os.O_RDONLY|os.O_NOFOLLOW)
        try:os.fsync(fd)
        finally:os.close(fd)
        fsync_dir(self.path.parent)


def stream(peer,source,destination,ttl=TTL,clock=time.monotonic,stopping=lambda:False,observe_queues=None):
    """Finite bounded opaque forwarding; EOF drains accepted output, then closes.

    A two-second drain deadline never exceeds the original absolute deadline.
    No input message, wire byte or parsed content is logged or persisted.
    """
    end=clock()+ttl;drain=None
    queues=[bytearray(),bytearray()]
    inputs=[source,peer];outputs=[peer,destination]
    sel=selectors.DefaultSelector()
    for endpoint in {source,destination,peer}:os.set_blocking(endpoint.fileno(),False)
    try:
        while clock()<end and not stopping():
            if drain is not None and (clock()>=drain or not any(queues)):return 'eof-drained'
            desired={}
            if drain is None:
                for n,endpoint in enumerate(inputs):
                    if len(queues[n])<QUEUE_LIMIT:desired[endpoint]=(selectors.EVENT_READ,n)
            for n,queue in enumerate(queues):
                require(len(queue)<=QUEUE_LIMIT)
                if queue:
                    endpoint=outputs[n]
                    flags,_=desired.get(endpoint,(0,n));desired[endpoint]=(flags|selectors.EVENT_WRITE,n)
            for key in list(sel.get_map().values()):
                if key.fileobj not in desired:sel.unregister(key.fileobj)
            for endpoint,(flags,n) in desired.items():
                try:sel.modify(endpoint,flags,n)
                except KeyError:sel.register(endpoint,flags,n)
            for key,events in sel.select(min(.2,max(0,end-clock()))):
                endpoint=key.fileobj
                if events&selectors.EVENT_READ:
                    n=0 if endpoint is source else 1
                    credit=QUEUE_LIMIT-len(queues[n])
                    if credit<=0:continue  # Ignore a stale read event at cap.
                    try:chunk=os.read(endpoint.fileno(),min(65536,credit))
                    except BlockingIOError:
                        time.sleep(.001);continue
                    if not chunk:
                        drain=min(end,clock()+2)
                    else:
                        queues[n].extend(chunk);require(len(queues[n])<=QUEUE_LIMIT)
                        if observe_queues:observe_queues(tuple(len(q) for q in queues))
                if events&selectors.EVENT_WRITE:
                    n=0 if endpoint is peer else 1
                    try:count=os.write(endpoint.fileno(),queues[n][:65536])
                    except BlockingIOError:
                        time.sleep(.001);continue
                    del queues[n][:count]
        return 'absolute-expiry' if clock()>=end else 'stop-requested'
    finally:
        sel.close();peer.close()


def run_remote(action,source_sha):
    guard_guest();require(re.fullmatch(r'[0-9a-f]{64}',source_sha))
    marker=Marker(ROOT,action)
    own=process_identity(os.getpid());require(own and own['uid']==501)
    state={'schema':1,'action':action,'sourceSHA256':source_sha,'identity':own,
           'phase':'starting','peer':'guest-loopback-5900','absoluteTTLSeconds':TTL,
           'wireBytesPersisted':False}
    stopping=False
    def stop(*_):
        nonlocal stopping
        stopping=True
    signal.signal(signal.SIGTERM,stop);signal.signal(signal.SIGINT,stop)
    marker.create(state)
    peer=None
    try:
        peer=socket.create_connection(('127.0.0.1',5900),timeout=5)
        state['phase']='streaming';marker.save(state)
        state['closedReason']=stream(peer,sys.stdin.buffer,sys.stdout.buffer,stopping=lambda:stopping)
    except Exception:
        state['closedReason']='stream-failed'
        raise
    finally:
        if peer is not None:peer.close()
        state.update(marker.read())  # Retain a separately durable stop intent.
        state['phase']='closed';state['socketClosed']=True;marker.save(state)


def checked_marker(action,source_sha,root=ROOT,identity=process_identity):
    require(re.fullmatch(r'[0-9a-f]{64}',source_sha))
    marker=Marker(root,action);state=marker.read()
    require(state.get('schema')==1 and state.get('action')==action and state.get('sourceSHA256')==source_sha)
    old=state['identity'];require(old['uid']==501 and isinstance(old['pid'],int) and 1<old['pid']<2**31)
    current=identity(old['pid'])
    if current is not None:require(current==old)
    return marker,state,current


def status_remote(action,source_sha):
    guard_guest();_,state,current=checked_marker(action,source_sha)
    return {'ownedAction':True,'action':action,'phase':state['phase'],
            'exactLifetimePresent':current is not None,'actualProcessAbsent':current is None,
            'identity':state['identity']}


def stop_remote(action,source_sha,root=ROOT,identity=process_identity,send_signal=os.kill,clock=time.monotonic,sleep=time.sleep):
    marker,state,current=checked_marker(action,source_sha,root,identity)
    if current is None:
        closed=state.get('phase')=='closed'
        if closed:marker.closed_durability_barrier()
        return {'ownedAction':True,'actualProcessAbsent':True,'signalCalls':0,'socketOwnerGone':True,'durableClosedMarker':closed}
    signal_calls=0
    if state.get('phase')!='closed':
        require(not state.get('stopRequested',False))
        state=marker.claim_stop_once(state['identity'])
        # Revalidate after durable admission and every potentially slow read.
        require(identity(current['pid'])==state['identity'])
        send_signal(current['pid'],signal.SIGTERM);signal_calls=1
    # A closed but not-yet-reaped owner needs only a bounded absence read.
    end=clock()+6
    while clock()<end:
        value=identity(current['pid'])
        if value is None:
            final=marker.read()
            require(final.get('phase')=='closed' and final.get('socketClosed') is True)
            marker.closed_durability_barrier()
            return {'ownedAction':True,'actualProcessAbsent':True,'signalCalls':signal_calls,'socketOwnerGone':True,'durableClosedMarker':True}
        require(value==state['identity'])
        sleep(.1)
    raise TimeoutError('owned remote RFB process absence not proven')


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('mode',choices=['run','status','stop'])
    parser.add_argument('action')
    parser.add_argument('source_sha')
    args=parser.parse_args()
    try:
        if args.mode=='run':run_remote(args.action,args.source_sha)
        else:
            guard_guest()
            result=status_remote(args.action,args.source_sha) if args.mode=='status' else stop_remote(args.action,args.source_sha)
            print(json.dumps(result))
    except Exception as error:
        if args.mode!='run':print(json.dumps({'ownedAction':False,'error':type(error).__name__,'retryAllowed':False}))
        return 70
    return 0


if __name__=='__main__':raise SystemExit(main())
