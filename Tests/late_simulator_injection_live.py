#!/usr/bin/env python3
"""Load the Xcode bridge into an already-active dependency-free Simulator app."""
import argparse
import json
from pathlib import Path
import plistlib
import shlex
import shutil
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--fixture', type=Path, required=True)
parser.add_argument('--bridge', type=Path, required=True)
parser.add_argument('--device', required=True)
parser.add_argument('--architecture', default='arm64', choices=['arm64', 'x86_64'])
parser.add_argument('--bundle', default='local.lookin.research.late')
parser.add_argument('--scheme', default='lookin-late-research')
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
bundle = args.bundle
app = args.output.resolve() / 'LateProbe.app'
shutil.copytree(args.fixture, app, dirs_exist_ok=True)
info = plistlib.loads((app / 'Info.plist').read_bytes())
info.update(CFBundleIdentifier=bundle, CFBundleDisplayName='Lookin Late Injection')
info['CFBundleURLTypes'] = [{'CFBundleURLName': bundle, 'CFBundleURLSchemes': [args.scheme]}]
(app / 'Info.plist').write_bytes(plistlib.dumps(info))

def run(command):
    return subprocess.check_output(list(map(str, command)), text=True, stderr=subprocess.STDOUT, timeout=50).strip()

def sim(*arguments): return run(['xcrun', 'simctl', *arguments])

run(['codesign', '--force', '--sign', '-', '--preserve-metadata=entitlements', app])
sim('install', args.device, app)
pid = int(sim('launch', args.device, bundle).rsplit(':', 1)[1])
container = Path(sim('get_app_container', args.device, bundle, 'data'))

def state(expected):
    deadline = time.monotonic() + 12
    while time.monotonic() < deadline:
        try:
            data = json.loads((container / 'Documents/state.json').read_text())
            if data['pid'] == pid and data['applicationState'] == 0 and bool(data['lookinLoaded']) == expected: return data
        except (OSError, ValueError): pass
        time.sleep(0.1)
    raise RuntimeError('The active fixture did not reach loaded=' + str(expected))

before = state(False)
commands = ['platform select ios-simulator',
            'target create --arch ' + args.architecture + ' ' + shlex.quote(str(app / info['CFBundleExecutable'])),
            'process attach --pid ' + str(pid), 'command script import -r ' + shlex.quote(str(args.bridge.resolve())),
            'lookin-xcode-load', 'process detach', 'quit']
command = ['xcrun', 'lldb', '--no-lldbinit', '--batch']
for item in commands: command += ['-o', item]
log = run(command)
(args.output / 'lldb.log').write_text(log)
after = state(True)
ports = run(['lsof', '-nP', '-a', '-p', str(pid), '-iTCP', '-sTCP:LISTEN'])
assert '127.0.0.1:47' in ports, ports
report = {'passed': True, 'pid': pid, 'before': before, 'after': after, 'ports': ports,
          'activationTransitionUsed': False, 'bundle': bundle}
(args.output / 'report.json').write_text(json.dumps(report, indent=2))
print(json.dumps({'passed': True, 'pid': pid, 'activationTransitionUsed': False}))
