import json,os,subprocess,time
from pathlib import Path
app=Path(os.environ['NOSLEEP_APP']).resolve()
exe=app/'Contents/MacOS/NoSleep'
data=Path.home()/'Library/Application Support/NoSleep'
def ui():
    try:return json.loads((data/'ui.json').read_text())
    except (OSError,ValueError):return {}
def state():
    try:return json.loads((data/'state.json').read_text())
    except (OSError,ValueError):return {}
def wait(f,desc):
    until=time.monotonic()+10
    while time.monotonic()<until:
        if f():print('PASS:',desc,flush=True);return
        time.sleep(.2)
    raise AssertionError((desc,ui(),state()))
def cmd(name):subprocess.run([str(exe),'--command',name],check=True)
def no_process():return subprocess.run(['/usr/bin/pgrep','-x','NoSleep'],capture_output=True).returncode!=0
# Called only after closing the previous app; does not install or alter any rights.
assert no_process(), 'Close other NoSleep before first-run simulation'
start=time.time()
subprocess.run(['/usr/bin/open',str(app),'--args','--preview-first-run'],check=True)
wait(lambda:state().get('updatedAt',0)>start and ui().get('setupVisible')==True,'first-run setup button is visible')
assert ui()['sleepEnabled']==False
assert ui()['errorText']==''
assert state()['systemWanted']==False
print('PASS: no premature sudo error; sleep waits for user setup',flush=True)
cmd('snapshot')
wait(lambda:(data/'window.png').exists(),'first-run window renders')
cmd('quit');wait(no_process,'first-run preview exits without changes')
start=time.time()
time.sleep(.7)
subprocess.run(['/usr/bin/open','-n',str(app)],check=True)
wait(lambda:state().get('updatedAt',0)>start and ui().get('setupVisible')==False,'existing power setup is detected automatically')
wait(lambda:ui().get('sleepEnabled')==True,'configured user can use sleep toggle immediately')
assert ui()['errorText']==''
print('PASS: existing setup needs no second password prompt',flush=True)
