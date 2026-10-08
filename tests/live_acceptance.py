import json, os, re, subprocess, time
from pathlib import Path
app=Path(os.environ.get('NOSLEEP_APP', str(Path(__file__).resolve().parents[1]/'build/NoSleep.app'))).resolve()
exe=app/'Contents/MacOS/NoSleep'
data=Path.home()/'Library/Application Support/NoSleep'
results=[]
def read(name):
    try:return json.loads((data/name).read_text())
    except (OSError, ValueError):return {}
def wait(predicate, description, timeout=10):
    end=time.monotonic()+timeout
    while time.monotonic()<end:
        if predicate():
            results.append(description); print('PASS:',description,flush=True); return
        time.sleep(.2)
    raise AssertionError(description+' '+str(read('state.json'))+' '+str(read('ui.json')))
def command(value):
    subprocess.run([str(exe),'--command',value],check=True)
def flags(s,d):
    v=read('state.json')
    return v.get('systemWanted')==s and v.get('systemActual')==s and v.get('displayWanted')==d and v.get('displayActual')==d and not v.get('error')
started_at=time.time()
wait(lambda:bool(read('state.json').get('pid')) and read('state.json').get('updatedAt',0)>started_at,'fresh live application state')
command('all-off'); wait(lambda:flags(False,False),'both protections OFF')
command('quit')
old_pid=read('state.json')['pid']
def gone():
    try:os.kill(old_pid,0);return False
    except ProcessLookupError:return True
wait(gone,'normal quit completes')
subprocess.run(['/usr/bin/open',str(app)],check=True)
wait(lambda:read('state.json').get('pid')!=old_pid and flags(False,False),'OFF preference survives reopening')
command('display-on');wait(lambda:flags(False,True),'display-only protection')
wait(lambda:read('ui.json').get('statusTitle')==' Экран','display-only status is not misleading ON')
command('display-off');wait(lambda:flags(False,False),'display protection released')
command('sleep-on');wait(lambda:flags(True,False),'system-only protection')
command('display-on');wait(lambda:flags(True,True),'both protections ON')
command('hide');wait(lambda:read('ui.json').get('windowVisible')==False,'closing window keeps protection active')
assert flags(True,True)
subprocess.run(['/usr/bin/open',str(app)],check=True)
wait(lambda:read('ui.json').get('windowVisible')==True,'opening existing app reopens control window')
started=time.monotonic()
subprocess.run(['/usr/bin/sudo','-n','/usr/bin/pmset','-a','disablesleep','0'],check=True)
def restored():
    text=subprocess.check_output(['/usr/bin/pmset','-g'],text=True)
    return bool(re.search(r'SleepDisabled\s+1',text))
wait(restored,'external reset recovered in running app',timeout=5)
print('Recovery seconds:',round(time.monotonic()-started,2),flush=True)
command('quit');pid=read('state.json')['pid']
def gone2():
    try:os.kill(pid,0);return False
    except ProcessLookupError:return True
wait(gone2,'quit after both protections enabled')
text=subprocess.check_output(['/usr/bin/pmset','-g'],text=True)
assert re.search(r'SleepDisabled\s+0',text),text
results.append('quit restores normal system sleep')
subprocess.run(['/usr/bin/open',str(app)],check=True)
wait(lambda:read('state.json').get('pid')!=pid and flags(True,True),'relaunch restores selected protections')
(data/'live-test-results.json').write_text(json.dumps({'passed':results},ensure_ascii=False,indent=2))
