#!/usr/bin/env python3
"""Prepare/freeze or explicitly execute full handoff in the existing owned VM.

Preparation performs only local code/archive validation and compilation. Execution
requires --run-owned-lab and a hashed prepared receipt, uses owned virtio-vsock,
never SSH/IP fallback or any host app/power lifecycle command. Timeout -> inspect
that exact execution, not restart. Cisco is accessed only through the owned server
anonymous session oracle and existing tunneled nonce; no auth/control commands.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import uuid
import zipfile

REPO = Path(__file__).resolve().parents[2]
SOURCE = Path(__file__).resolve().parent
BRIDGE_SOURCE_SHA = '57eb42f2e1822321fa348bae5bdda55e96fb3fbaf61c095fd54dab5b59c3a685'
BRIDGE_BINARY_SHA = '42c744640325a2fe1a0bb6c16e11584c8381826167e27b0847378a9cda4ae2a2'
OLD_SHA = '3f27d94d0532b3c8a608bf99cb3208d3eab9e812c02f9c7eae80db67db7e9ecd'
MAC = '42:35:8c:14:fd:0c'
VM = 'nosleep-vpn-lab-20261012'
RUN = 'f0b5145836a1'
SHA = re.compile(r'[a-f0-9]{64}\Z')
BUILD = REPO / 'build/power-handoff-owned'
SHARE = REPO / 'build/vpn-lab/guest-transfer'

class Refused(Exception):
    pass

def require(value, reason):
    if not value:
        raise Refused(reason)

def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name,path)
    module = importlib.util.module_from_spec(spec);sys.modules[name]=module;spec.loader.exec_module(module)
    return module

def owned_file(value, limit=64*1024*1024, taskflow=False):
    path=Path(value).absolute()
    require(path==path.resolve() and (path.is_relative_to(REPO/'build') or taskflow and path.is_relative_to(REPO/'.taskflow')) and path.is_file()
            and not path.is_symlink() and path.stat().st_size<=limit,'owned-artifact-refused')
    return path

def read_hashed(path, sha, limit=65536, taskflow=False):
    path=owned_file(path,limit,taskflow)
    require(type(sha) is str and SHA.fullmatch(sha) and digest(path)==sha,'manifest-hash-refused')
    return json.loads(path.read_bytes())

def sources():
    return {str(path.relative_to(REPO)):digest(path) for path in sorted((REPO/'Sources').glob('*.swift'))}

def runner_sources():
    return {str(path.relative_to(REPO)):digest(path) for path in
        [SOURCE/'run_owned_vm.py',SOURCE/'guest_operator.py',SOURCE/'owned_vm_probe.swift']}

def archive_facts(path):
    path=owned_file(path)
    with zipfile.ZipFile(path) as archive:
        entries=archive.infolist();require(len(entries)<=4096 and sum(x.file_size for x in entries)<=128*1024*1024,'archive-refused')
        binary=archive.getinfo('NoSleep.app/Contents/MacOS/NoSleep');info=archive.getinfo('NoSleep.app/Contents/Info.plist')
        require(binary.file_size<=64*1024*1024 and info.file_size<=32768,'archive-refused')
        exe=archive.read(binary);metadata=archive.read(info);parsed=plistlib.loads(metadata)
        require(parsed.get('CFBundleIdentifier')=='local.robert.keepawake' and parsed.get('CFBundleExecutable')=='NoSleep','archive-identity-refused')
        return {'path':str(path),'sha256':digest(path),'executableSHA256':hashlib.sha256(exe).hexdigest(),
                'infoSHA256':hashlib.sha256(metadata).hexdigest()}

def validate_manifest(value, current=True):
    require(type(value) is dict and set(value)=={'schema','wantedDisplay','requireConnectedTunnel','sourceHashes',
            'runnerHashes','bridgeSourceSHA256','artifacts','candidateBuildReceipt'},'manifest-shape-refused')
    require(type(value['schema']) is int and value['schema']==1 and type(value['wantedDisplay']) is bool and value['requireConnectedTunnel'] is True,
            'manifest-intent-refused')
    require(value['bridgeSourceSHA256']==BRIDGE_SOURCE_SHA and (not current or digest(SOURCE/'bridge.swift')==BRIDGE_SOURCE_SHA),
            'bridge-source-freeze-refused')
    require(not current or value['sourceHashes']==sources() and value['runnerHashes']==runner_sources(),'source-freeze-refused')
    require(set(value['artifacts'])=={'old','new','bridge'},'manifest-shape-refused')
    for kind in ('old','new'):
        require(value['artifacts'][kind]==archive_facts(value['artifacts'][kind]['path']),'archive-freeze-refused')
    build=value['candidateBuildReceipt'];require(type(build) is dict and set(build)=={'path','sha256'},'manifest-shape-refused')
    receipt=read_hashed(build['path'],build['sha256'],131072,taskflow=True)
    require(receipt.get('sourceHashes')==value['sourceHashes'] and receipt.get('binarySHA256')==value['artifacts']['new']['executableSHA256']
            and receipt.get('infoSHA256')==value['artifacts']['new']['infoSHA256'],'candidate-build-binding-refused')
    require(value['artifacts']['old']['executableSHA256']==OLD_SHA,'historical-old-refused')
    bridge=value['artifacts']['bridge'];require(set(bridge)=={'path','sha256'},'manifest-shape-refused')
    require(digest(owned_file(bridge['path'],8*1024*1024))==bridge['sha256']==BRIDGE_BINARY_SHA,'bridge-binary-freeze-refused')
    return value

def write_private(path,value):
    path.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
    with path.open('x') as stream:
        os.chmod(path,0o600);json.dump(value,stream,indent=2,sort_keys=True);stream.flush();os.fsync(stream.fileno())
    return digest(path)

def template(args):
    bridge=owned_file(args.bridge,8*1024*1024)
    value={'schema':1,'wantedDisplay':args.wanted_display=='1','requireConnectedTunnel':True,'sourceHashes':sources(),
           'runnerHashes':runner_sources(),'bridgeSourceSHA256':BRIDGE_SOURCE_SHA,'artifacts':{
               'old':archive_facts(args.old_archive),'new':archive_facts(args.new_archive),
               'bridge':{'path':str(bridge),'sha256':digest(bridge)}},
           'candidateBuildReceipt':{'path':str(owned_file(args.candidate_receipt,131072,taskflow=True)),
                                    'sha256':args.candidate_receipt_sha256}}
    validate_manifest(value)
    output=Path(args.output).absolute();require(output.is_relative_to(BUILD) and not output.exists(),'output-path-refused')
    sha=write_private(output,value)
    print(json.dumps({'manifest':str(output),'sha256':sha,'preparationOnly':True,'mainPowerActions':0,'vmActions':0}))

def prepare(args):
    manifest=validate_manifest(read_hashed(args.manifest,args.manifest_sha256))
    execution=str(uuid.uuid4());directory=BUILD/execution;directory.mkdir(mode=0o700,parents=True)
    probe=directory/'probe.bin'
    result=subprocess.run(['/usr/bin/xcrun','swiftc','-target','arm64-apple-macos14.0','-parse-as-library',
            str(SOURCE/'owned_vm_probe.swift'),'-o',str(probe)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=60)
    require(result.returncode==0,'probe-compile-refused')
    require(runner_sources()==manifest['runnerHashes'],'source-freeze-refused')
    share=SHARE/('power-handoff-'+execution);share.mkdir(mode=0o700)
    artifacts={}
    source_paths={'old':Path(manifest['artifacts']['old']['path']),'new':Path(manifest['artifacts']['new']['path']),
        'bridge':Path(manifest['artifacts']['bridge']['path']),'probe':probe,'operator':SOURCE/'guest_operator.py'}
    for kind,path in source_paths.items():
        name='guest_operator.py' if kind=='operator' else kind+('.zip' if kind in ('old','new') else '.bin')
        target=share/name;shutil.copyfile(path,target);target.chmod(0o600)
        item={'file':name,'sha256':digest(target)}
        if kind in ('old','new'):
            item.update({key:manifest['artifacts'][kind][key] for key in ('executableSHA256','infoSHA256')})
        else:
            signature=subprocess.run(['/usr/bin/codesign','--verify','--strict',str(target)],stdout=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL,timeout=8) if kind!='operator' else None
            require(signature is None or signature.returncode==0,'artifact-signature-refused')
        require(digest(path)==item['sha256'],'immutable-copy-refused');artifacts[kind]=item
    config={'schema':1,'execution':execution,'vm':VM,'mac':MAC,'run':RUN,'wantedDisplay':manifest['wantedDisplay'],
            'requireConnectedTunnel':True,'artifacts':artifacts,'manifestSHA256':args.manifest_sha256}
    guest=load_module('power_guest_contract',SOURCE/'guest_operator.py');guest.validate_config(config)
    config_path=share/'configuration.json';config_sha=write_private(config_path,config)
    prepared={'schema':1,'execution':execution,'manifest':str(Path(args.manifest).absolute()),'manifestSHA256':args.manifest_sha256,
        'configPath':str(config_path),'configSHA256':config_sha,'sourceHashes':manifest['sourceHashes'],
        'runnerHashes':manifest['runnerHashes'],'scope':'preparation-only; no runtime/VM/power actions','actualFullHandoffProven':False,
        'mainActions':0,'vmActions':0}
    path=directory/'prepared.json';sha=write_private(path,prepared)
    print(json.dumps({'preparedReceipt':str(path),'sha256':sha,'execution':execution,'actualExecutionAttempted':False}))

def validated_prepared(args, current):
    prepared=read_hashed(args.prepared,args.prepared_sha256)
    require(prepared.get('schema')==1 and str(uuid.UUID(prepared['execution']))==prepared['execution'],'prepared-shape-refused')
    validate_manifest(read_hashed(prepared['manifest'],prepared['manifestSHA256']),current=current)
    config=read_hashed(prepared['configPath'],prepared['configSHA256'],32768)
    module=load_module('power_guest_validate',SOURCE/'guest_operator.py');module.validate_config(config)
    require(config['execution']==prepared['execution'] and config['manifestSHA256']==prepared['manifestSHA256'],'prepared-shape-refused')
    share=Path(prepared['configPath']).parent
    require(share==SHARE/('power-handoff-'+prepared['execution']),'prepared-share-refused')
    for artifact in config['artifacts'].values():
        require(digest(owned_file(share/artifact['file']))==artifact['sha256'],'artifact-hash-refused')
    return prepared,config

def runtime():
    # Loaded only behind the explicit execute/inspect switches, not default/prepare/tests.
    guest=load_module('power_owned_transport',REPO/'infra/vpn-lab/guest_command.py')
    lab=load_module('power_owned_server',REPO/'infra/vpn-lab/lab.py')
    guest.vsock_base()
    return guest,lab.Lab(REPO/'build/vpn-lab/runs'/RUN)

def invoke(guest,prepared,inspect):
    share='/Volumes/My Shared Files/power-handoff-'+prepared['execution']
    command=['/usr/bin/python3',share+'/guest_operator.py','--inspect' if inspect else '--execute',
             '--config',share+'/configuration.json','--config-sha256',prepared['configSHA256']]
    return guest.run('exec '+shlex.join(command)+'\n',timeout=30 if inspect else 360,output_limit=65536)

def run_or_inspect(args,inspect=False):
    prepared,config=validated_prepared(args,current=not inspect);guest,lab=runtime()
    if inspect:
        code,raw=invoke(guest,prepared,True)
        require(code==0,'inspection-refused');print(raw.strip());return
    directory=BUILD/prepared['execution'];receipt=directory/'execution.json'
    require(not receipt.exists(),'existing-execution-checkpoint-refused')
    lab.invariants();before=lab.native_clients()
    require(lab.health() and before['clientCount']==1 and before['states']==['connected'],'connected-server-precondition-refused')
    checkpoint={'schema':1,'execution':prepared['execution'],'result':'running','phase':'dispatch-checkpoint',
        'guestRoot':'/Users/admin/NoSleepLab/power-handoff/runs/'+prepared['execution'],'serverBefore':before,
        'preparedReceiptSHA256':args.prepared_sha256,'mainActions':0,'vpnAuthenticationActions':0,'actualFullHandoffProven':False}
    write_private(receipt,checkpoint)
    try:
        code,raw=invoke(guest,prepared,False)
        require(len(raw.encode())<=65536,'guest-output-budget')
        value=json.loads(raw)
        require(type(value) is dict and value.get('execution')==prepared['execution'],'guest-envelope-unconfirmed')
    except Exception:
        checkpoint.update(result='observation-incomplete',phase='inspect-same-execution-required',processTerminalProven=False)
        # Never restart or infer terminal from a transport timeout.
        with receipt.open('w') as stream:
            json.dump(checkpoint,stream,indent=2);stream.flush();os.fsync(stream.fileno())
        print(json.dumps({'receipt':str(receipt),'execution':prepared['execution'],'inspectionRequired':True}));return
    after=lab.native_clients()
    same=after==before
    checkpoint.update(result='passed' if code==0 and value.get('fullHandoffProven') is True and same else 'failed',
        phase='terminal',guestReceipt=value,serverAfter=after,serverSessionUnchanged=same,
        actualFullHandoffProven=code==0 and value.get('fullHandoffProven') is True and same,guestCommandExit=code)
    with receipt.open('w') as stream:
        json.dump(checkpoint,stream,indent=2);stream.flush();os.fsync(stream.fileno())
    print(json.dumps({'receipt':str(receipt),'sha256':digest(receipt),'fullHandoffProven':checkpoint['actualFullHandoffProven'],
                     'mainActions':0}));require(checkpoint['actualFullHandoffProven'],'full-handoff-unproven')

def main():
    parser=argparse.ArgumentParser()
    modes=parser.add_mutually_exclusive_group(required=True)
    modes.add_argument('--make-manifest',action='store_true');modes.add_argument('--prepare',action='store_true')
    modes.add_argument('--run-owned-lab',action='store_true');modes.add_argument('--inspect-owned-lab',action='store_true')
    parser.add_argument('--old-archive');parser.add_argument('--new-archive');parser.add_argument('--bridge')
    parser.add_argument('--wanted-display',choices=('0','1'));parser.add_argument('--output')
    parser.add_argument('--candidate-receipt');parser.add_argument('--candidate-receipt-sha256')
    parser.add_argument('--manifest');parser.add_argument('--manifest-sha256')
    parser.add_argument('--prepared');parser.add_argument('--prepared-sha256')
    args=parser.parse_args()
    if args.make_manifest:
        require(all((args.old_archive,args.new_archive,args.bridge,args.output,args.wanted_display is not None,
                    args.candidate_receipt,args.candidate_receipt_sha256)),'arguments-refused');template(args)
    elif args.prepare:
        require(args.manifest and args.manifest_sha256,'arguments-refused');prepare(args)
    else:
        require(args.prepared and args.prepared_sha256,'arguments-refused');run_or_inspect(args,args.inspect_owned_lab)

if __name__=='__main__':
    try:
        main()
    except Refused as failure:
        print(json.dumps({'result':'refused','reason':str(failure),'mainActions':0}));raise SystemExit(1)
    except Exception:
        print(json.dumps({'result':'failed','reason':'bounded-handoff-runner-error','mainActions':0}));raise SystemExit(1)
