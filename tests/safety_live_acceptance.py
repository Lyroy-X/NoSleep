"""Candidate UI acceptance; restores the installed app and the user's two power preferences.
No VPN connect/disconnect, credentials, or profile writes occur.
"""
import os,subprocess,json,time,plistlib,hashlib,zipfile,threading
from pathlib import Path
repo=Path(__file__).resolve().parents[1]
app=Path(os.environ.get('NOSLEEP_APP',repo/'build/NoSleep.app')).resolve(); exe=app/'Contents/MacOS/NoSleep'
installed=repo.parent/'NoSleep.app'; data=Path.home()/'Library/Application Support/NoSleep'
results=[]
query_pids=set(); samples=[]; sampling=threading.Event(); sample_done=threading.Event()
def sampler():
    while not sample_done.is_set():
        pid=read('state.json').get('pid')
        process=subprocess.check_output(['/bin/ps','-axo','pid,ppid,rss,comm'],text=True)
        for line in process.splitlines()[1:]:
            fields=line.split(None,3)
            if len(fields)<4:continue
            if int(fields[0])==pid and fields[3].endswith('/NoSleep'): samples.append(int(fields[2]))
            if int(fields[1])==pid and fields[3].endswith('/vpn'):query_pids.add(int(fields[0]))
        sample_done.wait(.5)
def owned_queries():
    pid=read('state.json').get('pid')
    rows=subprocess.check_output(['/bin/ps','-axo','pid,ppid,comm'],text=True).splitlines()[1:]
    return [line for line in rows if len(line.split(None,2))==3 and int(line.split(None,2)[1])==pid and line.split(None,2)[2].endswith('/vpn')]

def read(name):
    try:return json.loads((data/name).read_text())
    except (OSError,ValueError):return {}
def wait(predicate,label,timeout=12):
    until=time.monotonic()+timeout
    while time.monotonic()<until:
        if predicate():results.append(label);print('PASS:',label,flush=True);return
        time.sleep(.2)
    raise AssertionError(label)
def cmd(value):subprocess.run([str(exe),'--command',value],check=True)
def flags(s,d):
    v=read('state.json')
    return v.get('systemWanted')==s and v.get('systemActual')==s and v.get('displayWanted')==d and v.get('displayActual')==d and not v.get('error')
def state():
    p=subprocess.run(['/opt/cisco/secureclient/bin/vpn','-s','state'],stdin=subprocess.DEVNULL,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=12)
    a={'подключено':'connected','connected':'connected','отключено':'disconnected','disconnected':'disconnected'}
    values=[a.get(s.split('state:',1)[1].strip().casefold(),'unknown') for s in p.stdout.splitlines() if 'state:' in s]
    assert p.returncode==0
    return next((s for s in reversed(values) if s!='unknown'),'unknown')
def stopped():return subprocess.run(['pgrep','-x','NoSleep'],stdout=subprocess.DEVNULL).returncode==1
observer_pref=subprocess.run(['defaults','read','local.robert.keepawake','CiscoObservationEnabled'],capture_output=True,text=True)
original_observer=None if observer_pref.returncode else observer_pref.stdout.strip() in ['1','true']
pause_pref=subprocess.run(['defaults','read','local.robert.keepawake','CiscoObservationPause'],capture_output=True,text=True)
original_pause=None if pause_pref.returncode else pause_pref.stdout.strip()
agent_before=subprocess.check_output(['pgrep','-x','vpnagentd'],text=True).strip()
original=read('state.json'); original_s=bool(original.get('systemWanted')); original_d=bool(original.get('displayWanted'))
profile=Path('/opt/cisco/secureclient/vpn/profile/VPN.X5M.xml'); before_hash=hashlib.sha256(profile.read_bytes()).hexdigest()
policy=Path('/opt/cisco/secureclient/AnyConnectLocalPolicy.xml'); policy_hash=hashlib.sha256(policy.read_bytes()).hexdigest()
before_vpn=state(); assert before_vpn=='connected','Working VPN is a prerequisite; do not run disruptive tests'
subprocess.run([str(installed/'Contents/MacOS/NoSleep'),'--command','quit'],check=True)
wait(stopped,'previous NoSleep stopped cleanly')
try:
    started=time.time(); subprocess.run(['open','-n',str(app)],check=True)
    wait(lambda:read('state.json').get('updatedAt',0)>started and read('ui.json').get('sleepEnabled') is True,'candidate startup and power permissions ready')
    wait(lambda:read('ui.json').get('nativeRecovery')=='enabled','real Cisco native AutoReconnect policy recognized')
    worker=threading.Thread(target=sampler,daemon=True);worker.start()
    if original_observer is None:
        wait(lambda:read('ui.json').get('observerEnabled') is True,'status observation is available out of the box')
    if owned_queries():
        cmd('observer-off');wait(lambda:read('ui.json').get('observerEnabled') is False and not owned_queries(),'disabling cancels only the owned status query')
    cmd('all-off'); wait(lambda:flags(False,False) and read('ui.json').get('observerEnabled') is False and read('ui.json').get('allButtonTitle')=='Включить всё','all off shows enable-all action')
    cmd('display-on'); wait(lambda:flags(False,True) and read('ui.json').get('allButtonTitle')=='Выключить всё','partial activation shows disable-all action')
    cmd('toggle-all'); wait(lambda:flags(False,False),'combined action disables partial activation')
    cmd('toggle-all'); wait(lambda:flags(True,True) and read('ui.json').get('observerEnabled') is True,'combined action enables both protections and observation')
    cmd('hide');wait(lambda:read('ui.json').get('windowVisible') is False and flags(True,True),'closing window preserves protections')
    cmd('show');wait(lambda:read('ui.json').get('windowVisible') is True,'control window reopens')
    wait(lambda:read('ui.json').get('vpnState')=='connected' and read('ui.json').get('observerIssue')=='none','bounded observation reports the working native Cisco session',timeout=75)
    assert len(query_pids)<=2, 'Unexpected CLI polling frequency'
    results.append('no rapid CLI polling while toggling/closing/reopening');print('PASS:',results[-1],flush=True)
    cmd('snapshot'); picture=data/'window.png'; snapshot_start=time.time()
    wait(lambda:picture.exists() and picture.stat().st_mtime>snapshot_start-1,'fresh application UI snapshot rendered')
    archive=data/'last-support-test.zip';archive.unlink(missing_ok=True)
    cmd('export-test')
    wait(lambda:archive.exists(),'manual diagnostic archive produced')
    with zipfile.ZipFile(archive) as z:
        assert set(z.namelist())=={'README.txt','summary.json','events.jsonl'}
        summary=json.loads(z.read('summary.json'));assert summary['format']==2 and summary['appVersion']==plistlib.loads((app/'Contents/Info.plist').read_bytes())['CFBundleShortVersionString']
        assert summary['observer']['nativeRecovery']=='enabled' and summary['observer']['link']=='connected'
        assert set(summary['power'])<= {'sleepWanted','sleepActual','displayWanted','displayActual','observerEnabled','vpnState','nativeRecovery','online','issue','number'}
        for line in z.read('events.jsonl').splitlines():
            entry=json.loads(line);assert set(entry)=={'at','kind','facts'}
            assert set(entry['facts'])<= {'sleepWanted','sleepActual','displayWanted','displayActual','observerEnabled','vpnState','nativeRecovery','online','issue','number'}
    assert archive.stat().st_size<=200_000_000+256*1024
    results.append('archive has only allowlisted schema, no raw output, and bounded size');print('PASS:',results[-1],flush=True)
    cmd('all-off');wait(lambda:flags(False,False) and read('ui.json').get('observerEnabled') is False,'all owned functions release; Cisco remains independent')
    cmd('quit');wait(stopped,'candidate quits with functions off')
    restart=time.time();subprocess.run(['open','-n',str(app)],check=True)
    wait(lambda:read('state.json').get('updatedAt',0)>restart and flags(False,False) and read('ui.json').get('observerEnabled') is False,'explicit OFF survives app restart')
    assert not owned_queries(), 'Disabled observer launched CLI'
    pid=read('state.json')['pid'];subprocess.run([str(exe)],check=True,timeout=8)
    wait(lambda:read('state.json').get('pid')==pid and len(subprocess.check_output(['pgrep','-x','NoSleep'],text=True).splitlines())==1,'duplicate launch reuses one application and one watchdog')
    assert state()==before_vpn,'VPN changed during NoSleep UI acceptance'
    assert hashlib.sha256(profile.read_bytes()).hexdigest()==before_hash
    assert hashlib.sha256(policy.read_bytes()).hexdigest()==policy_hash
    assert subprocess.check_output(['pgrep','-x','vpnagentd'],text=True).strip()==agent_before
    results.append('working Cisco connection and profile remain unchanged');print('PASS:',results[-1],flush=True)
finally:
    sample_done.set()
    cmd('quit');wait(stopped,'candidate quit completes')
    for key,value in [('PreventSystemSleep',original_s),('KeepDisplayAwake',original_d)]:subprocess.run(['defaults','write','local.robert.keepawake',key,'-bool',str(value).lower()],check=True)
    if original_observer is None:subprocess.run(['defaults','delete','local.robert.keepawake','CiscoObservationEnabled'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    else:subprocess.run(['defaults','write','local.robert.keepawake','CiscoObservationEnabled','-bool',str(original_observer).lower()],check=True)
    if original_pause is None:subprocess.run(['defaults','delete','local.robert.keepawake','CiscoObservationPause'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    else:subprocess.run(['defaults','write','local.robert.keepawake','CiscoObservationPause','-string',original_pause],check=True)
    started=time.time();subprocess.run(['open',str(installed)],check=True)
    wait(lambda:read('state.json').get('updatedAt',0)>started and flags(original_s,original_d),'installed stable app and original user power preferences restored')
receipt={'level':'e2e','environment':'local','sourceBase':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),'appHash':hashlib.sha256(exe.read_bytes()).hexdigest(),'results':results,'VPNConnectCommands':0,'VPNDisconnectCommands':0,'ownedStatusQueryPidsObserved':len(query_pids),'rssKiBRange':[min(samples),max(samples)] if samples else None,'screenshot':str(data/'window.png')}
(repo/'.taskflow/safety/core-e2e.json').write_text(json.dumps(receipt,indent=2))
