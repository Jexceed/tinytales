#!/usr/bin/env python3
"""Check microphone consent across a re-signed local update, without recording.
Initial OS authorization is requested only with --grant-initial and an unlocked screen.
"""
import argparse
import json
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
APP = Path('/Applications/小小故事屋.app')
REPORT = ROOT/'artifacts/v055-permission-reuse.json'

def screen_locked():
    code = 'import CoreGraphics; let d = CGSessionCopyCurrentDictionary() as? [String:Any] ?? [:]; print(d["CGSSessionScreenIsLocked"] as? Bool ?? false)'
    r = subprocess.run(['swift','-e',code],capture_output=True,text=True,check=True)
    return r.stdout.strip() == 'true'

def signature():
    r = subprocess.run(['codesign','-d','-r-','--verbose=4',str(APP)],capture_output=True,text=True,check=True)
    content = r.stdout + r.stderr
    return next(line for line in content.splitlines() if line.startswith('designated =>')), re.search(r'^CDHash=(.+)$', content, re.M).group(1)

def own_processes(report):
    r = subprocess.run(['pgrep','-f',str(report)],capture_output=True,text=True)
    return [int(pid) for pid in r.stdout.split()]

def diagnostic(report, request=False):
    args = ['open','-n',str(APP),'--args','--verify-audio',str(report),'--permission-only']
    if request: args.append('--request-microphone')
    subprocess.run(args,check=True)
    deadline = time.monotonic()+20
    script = '''tell application "System Events"
 if exists process "UserNotificationCenter" then
  tell process "UserNotificationCenter"
   repeat with targetWindow in windows
    repeat with targetText in (value of every static text of targetWindow)
     if (contents of targetText) is not missing value then
      if (contents of targetText) contains "小小故事屋" and (contents of targetText) contains "麦克风" then
       if exists button "允许" of targetWindow then
        click button "允许" of targetWindow
        return "confirmed"
       end if
      end if
     end if
    end repeat
   end repeat
  end tell
 end if
 return "pending"
end tell'''
    while not report.exists() and time.monotonic() < deadline:
        if request: subprocess.run(['osascript','-e',script],capture_output=True,timeout=2)
        time.sleep(.2)
    if not report.exists():
        for pid in own_processes(report): subprocess.run(['kill',str(pid)],capture_output=True)
        raise RuntimeError('Permission check did not complete; no setting was overridden')
    result = json.loads(report.read_text())
    for _ in range(15):
        if not own_processes(report): break
        time.sleep(.1)
    return result

def sign():
    subprocess.run(['python3',str(ROOT/'scripts/sign-macos.py'),str(APP)],check=True)
    subprocess.run(['codesign','--verify','--deep','--strict',str(APP)],capture_output=True,check=True)

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--grant-initial',action='store_true');parser.add_argument('--report',type=Path,default=REPORT);args=parser.parse_args();report_path=args.report
    if args.grant_initial and screen_locked():
        print('Screen locked: no permission prompt was requested.');return
    with tempfile.TemporaryDirectory(prefix='tinytales-identity-',dir='/tmp') as temporary:
        temporary=Path(temporary)
        before=diagnostic(temporary/'before.json')
        if before['permission'] == 0 and args.grant_initial:
            before=diagnostic(temporary/'initial-consent.json',request=True)
        if before['permission'] != 3:
            report_path.write_text(json.dumps({'success':False,'needsInitialAuthorization':True,'permission':before['permission'],'microphoneOpened':False},indent=2)+'\n')
            print('Initial microphone consent is not present; no update probe was performed.');return
        before_req,before_hash=signature()
        info_path=APP/'Contents/Info.plist';original=info_path.read_bytes()
        try:
            info=plistlib.loads(original);info['TinyTalesIdentityProbe']=uuid.uuid4().hex
            info_path.write_bytes(plistlib.dumps(info));sign()
            after_req,after_hash=signature()
            after=diagnostic(temporary/'updated.json')
            assert before_req == after_req and before_hash != after_hash
            assert after['permission'] == 3, 'Updated identity did not retain microphone consent'
            result={'success':True,'beforePermission':before['permission'],'afterUpdatePermission':after['permission'],'changedCodeDirectory':before_hash!=after_hash,'sameDesignatedRequirement':before_req==after_req,'updatedBuildRequestedPermission':False,'microphoneOpened':False}
        finally:
            info_path.write_bytes(original);sign()
        restored=diagnostic(temporary/'restored.json')
        assert restored['permission'] == 3
        result['restoredBuildPermission']=restored['permission']
        report_path.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
    subprocess.run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister','-f',str(APP)],check=True)

if __name__=='__main__':main()
