"""Read-only status for native settings; returns no logs, paths or credentials."""
from __future__ import annotations
import json
import argparse
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[1]
COMPONENTS = {'ahk':'快捷键主进程', 'hud':'界面与主托盘', 'caret':'光标定位', 'powerPolicy':'电源管理', 'rgb':'氛围灯进程'}
STATES = {'running','not-running','ambiguous','query-failed','unresponsive','outdated','disabled','missing'}


def sanitize(runtime: dict, enabled: dict, stamp: str, commit: str, *, limited: bool = False) -> dict:
    residents = runtime.get('residents', {})
    rows = []
    for name, label in COMPONENTS.items():
        entry = residents.get(name, {})
        state = entry.get('status')
        if state not in STATES: state = 'query-failed'
        if limited and state in {'not-running','missing'}: state = 'query-failed'
        module = 'power' if name == 'powerPolicy' else name
        if enabled.get(module) is False: state = 'disabled'
        rows.append({'id':name, 'label':label, 'state':state, 'evidence':'process-only' if name=='rgb' else 'metadata'})
    return {'version':1, 'status':'ok', 'collected_utc':datetime.now(timezone.utc).isoformat(),
            'commit':commit if re.fullmatch('[0-9a-f]{40}',commit) else '',
            'source_stamp':stamp if re.fullmatch('[0-9a-f]{64}',stamp) else '', 'components':rows}


def process_identity(pid: int) -> tuple[str, str] | None:
    """Limited-query handles suffice even when WMI cannot enumerate other hosts."""
    if os.name != 'nt': return None
    import ctypes
    from ctypes import wintypes as w
    kernel=ctypes.WinDLL('kernel32',use_last_error=True)
    kernel.OpenProcess.argtypes=[w.DWORD,w.BOOL,w.DWORD];kernel.OpenProcess.restype=w.HANDLE
    kernel.CloseHandle.argtypes=[w.HANDLE]
    kernel.QueryFullProcessImageNameW.argtypes=[w.HANDLE,w.DWORD,w.LPWSTR,ctypes.POINTER(w.DWORD)]
    kernel.GetProcessTimes.argtypes=[w.HANDLE,ctypes.c_void_p,ctypes.c_void_p,ctypes.c_void_p,ctypes.c_void_p]
    kernel.GetExitCodeProcess.argtypes=[w.HANDLE,ctypes.POINTER(w.DWORD)]
    handle=kernel.OpenProcess(0x1000,False,pid)
    if not handle:return None
    try:
        path=ctypes.create_unicode_buffer(32768);size=w.DWORD(len(path));code=w.DWORD()
        times=[ctypes.c_ulonglong() for _ in range(4)]
        if not kernel.GetExitCodeProcess(handle,ctypes.byref(code)) or code.value!=259:return None
        if not kernel.QueryFullProcessImageNameW(handle,0,path,ctypes.byref(size)):return None
        if not kernel.GetProcessTimes(handle,*(ctypes.byref(value) for value in times)):return None
        return path.value,str(times[0].value)
    finally:kernel.CloseHandle(handle)


def verified_power() -> str | None:
    path=Path(os.environ.get('USERPROFILE',str(Path.home())))/'AppData/Local/lat3ncy-toolbox/power-policy-status.json'
    try:
        with path.open('rb') as stream:raw=stream.read(65537)
        if len(raw)>65536:return None
        beat=json.loads(raw.decode('utf-8-sig'))
        if beat.get('identityVersion')!=1 or Path(beat['repoRoot']).resolve()!=ROOT.resolve() or Path(beat['scriptPath']).resolve()!=(ROOT/'tools/power-policy/PowerPolicy.ps1').resolve():return None
        age=(datetime.now(timezone.utc)-datetime.fromisoformat(beat['updatedUtc'].replace('Z','+00:00'))).total_seconds()
        if not -5<=age<=60:return None
        identity=process_identity(int(beat['pid']))
        if not identity or Path(identity[0]).name.lower() not in {'powershell.exe','pwsh.exe'} or identity[1]!=str(beat['startTicks']):return None
        names=['PowerPolicy.ps1','PowerPolicy.Core.ps1','PowerNative.cs','PowerPolicy.Identity.ps1','Repair-TaskHost.ps1','Run-PowerPolicy.vbs','config.toml','..\\ToolboxControls.ps1']
        lines=[]
        for name in names:
            source=ROOT/'tools/power-policy'/name.replace('\\','/')
            if source.exists():
                if source.stat().st_size>2097152:return None
                digest=hashlib.sha256(source.read_bytes()).hexdigest().upper()
            else:digest='missing'
            lines.append(name+'|'+digest)
        fingerprint=hashlib.sha256('\n'.join(lines).encode()).hexdigest()
        return 'running' if fingerprint==beat.get('sourceFingerprint') else 'outdated'
    except (OSError,ValueError,KeyError,TypeError):return None


def verified_caret(now: datetime | None = None) -> bool:
    """AHK attests the exact child it launched; no coordinates/text are read."""
    now=now or datetime.now(timezone.utc)
    try:
        with (ROOT/'.toolbox-state/caret-status.json').open('rb') as stream:raw=stream.read(4097)
        if len(raw)>4096:return False
        beat=json.loads(raw.decode('utf-8-sig'))
        if beat.get('version')!=1 or type(beat.get('updated_unix')) is not int:return False
        if not -5<=now.timestamp()-beat['updated_unix']<=20:return False
        digest=2166136261
        for value in str(ROOT.resolve()).rstrip('\\/').lower().encode('utf-8'):digest=((digest^value)*16777619)&0xffffffff
        if beat.get('repo_hash')!=format(digest,'08x'):return False
        if type(beat.get('owner_pid')) is not int or type(beat.get('pid')) is not int or beat['pid']<=0 or beat['owner_pid']<=0:return False
        owner=process_identity(beat['owner_pid']);child=process_identity(beat['pid'])
        if not owner or not child:return False
        if not re.fullmatch(r'AutoHotkey(?:32|64|UX)?\.exe',Path(owner[0]).name,re.IGNORECASE) or Path(child[0]).name.lower() not in {'powershell.exe','pwsh.exe'}:return False
        return owner[1]==beat.get('owner_ticks') and child[1]==beat.get('start_ticks')
    except (OSError,ValueError,KeyError,TypeError):return False


def diagnostic_summary(report: dict) -> list[dict]:
    rows=[]
    for name,label in (('translate','翻译环境'),('tts','朗读环境'),('ocr','截图识别环境')):
        config=report.get('configs',{}).get(name,{})
        runtime=report.get('modules',{}).get(name,{})
        config_state=config.get('status','query-failed')
        runtime_state=runtime.get('status','query-failed')
        if config_state not in {'ok','default','invalid'}:config_state='query-failed'
        if runtime_state not in {'ok','attention','not-applicable','invalid','missing','query-failed'}:runtime_state='query-failed'
        mismatches=runtime.get('mismatches',[])
        count=min(100,len(mismatches)) if isinstance(mismatches,list) else 0
        reason=('dependencies' if count else 'temp_unwritable' if runtime.get('tempWritable') is False else
                'limited_integrity' if runtime.get('integrity')=='low' else
                'unavailable' if runtime_state not in {'ok','not-applicable'} else 'none')
        rows.append({'id':name,'label':label,'config_state':config_state,'runtime_state':runtime_state,
                     'runtime_reason':reason,'dependency_mismatches':count})
    return rows


def full_diagnostics() -> list[dict]:
    try:
        import importlib.util
        spec=importlib.util.spec_from_file_location('toolbox_settings_doctor',ROOT/'tools/diagnostics/doctor.py')
        doctor=importlib.util.module_from_spec(spec);spec.loader.exec_module(doctor)
        return diagnostic_summary(doctor.collect(include_logs=False))
    except (OSError,ValueError,RuntimeError,ImportError,TypeError,KeyError):return diagnostic_summary({})


def collect(owner_pid: int = 0, *, full: bool = False) -> dict:
    sys.path.insert(0, str(ROOT/'tools'))
    import toolbox_controls as controls
    enabled={name:controls.module_enabled(name) for name in ('power','rgb')}
    powershell=Path(os.environ.get('SystemRoot','C:/Windows'))/'System32/WindowsPowerShell/v1.0/powershell.exe'
    runtime={}
    if os.name=='nt':
        environment=os.environ.copy();environment['PSModulePath']=str(powershell.parent/'Modules')
        try:
            result=subprocess.run([str(powershell),'-NoProfile','-ExecutionPolicy','Bypass','-File',str(ROOT/'tools/diagnostics/Collect-Runtime.ps1'),'-Repo',str(ROOT),'-ResidentsOnly'],capture_output=True,timeout=12,env=environment,creationflags=subprocess.CREATE_NO_WINDOW)
            if result.returncode==0 and len(result.stdout)<=65536: runtime=json.loads(result.stdout.decode('utf-8-sig'))
        except (OSError,ValueError,subprocess.TimeoutExpired): pass
    # Native requests prove their own live HUD identity independently of WMI.
    identity=process_identity(owner_pid) if owner_pid>0 else None
    limited=bool(owner_pid)
    runtime.setdefault('residents',{})
    if identity and Path(identity[0]).resolve()==(ROOT/'tools/ime-hud-winui/out/ImeHudWinUi.exe').resolve():
        runtime['residents']['hud']={'status':'running'}
    power=verified_power()
    if power:runtime['residents']['powerPolicy']={'status':power}
    if verified_caret():runtime['residents']['caret']={'status':'running'}
    try:
        commit=subprocess.run(['git','-C',str(ROOT),'rev-parse','HEAD'],capture_output=True,text=True,timeout=2,creationflags=subprocess.CREATE_NO_WINDOW if os.name=='nt' else 0).stdout.strip()
    except (OSError,subprocess.TimeoutExpired): commit=''
    try: stamp=(ROOT/'tools/ime-hud-winui/out/.source-stamp').read_text('utf-8-sig')[:128].strip()
    except OSError: stamp=''
    result=sanitize(runtime,enabled,stamp,commit,limited=limited)
    if full:result['diagnostics']=full_diagnostics()
    return result


def main() -> int:
    if hasattr(sys.stdout,'reconfigure'):sys.stdout.reconfigure(encoding='utf-8')
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--owner-pid',type=int,default=0);parser.add_argument('--full',action='store_true');args=parser.parse_args()
    try:result=collect(args.owner_pid,full=args.full)
    except (OSError,ValueError,TypeError):result=sanitize({}, {}, '', '')
    print(json.dumps(result,ensure_ascii=False));return 0

if __name__=='__main__':raise SystemExit(main())
