"""Run the production manager/loader against two disposable iOS Simulators."""
from pathlib import Path
import argparse
import json
import os
import plistlib
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--client', type=Path, required=True)
parser.add_argument('--server', type=Path, required=True)
parser.add_argument('--fixture', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
client = args.client.resolve()
server = args.server.resolve()
selected = 'local.lookin.research.autoconnect'
other = 'local.lookin.research.unselected'
environment = {k: v for k, v in os.environ.items() if not k.startswith(('SIMCTL_CHILD_', 'DYLD_'))}
report = {'passed': False, 'checks': {}}
devices = []
host = None

def run(command, **kwargs):
    return subprocess.run(list(map(str, command)), env=environment, capture_output=True, text=True, timeout=60, **kwargs)

def sim(*arguments, check=True):
    try:
        result = run(['xcrun', 'simctl', *arguments])
    except subprocess.TimeoutExpired:
        if arguments[0] == 'launch':
            device = arguments[-2]
            logs = run(['xcrun', 'simctl', 'spawn', device, 'log', 'show', '--last', '2m', '--style', 'compact', '--predicate', 'eventMessage CONTAINS "research.autoconnect" OR process == "Research"'])
            (args.output / 'launch-timeout.log').write_text(logs.stdout + logs.stderr)
        raise
    if arguments[0] == 'install':
        for attempt in range(2):
            if result.returncode == 0 or 'IXErrorDomain' not in result.stderr: break
            report.setdefault('installation_retries', []).append(result.stderr)
            time.sleep(1)
            result = run(['xcrun', 'simctl', *arguments])
    if check and result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result.stdout.strip()

def wait_for(check, label, seconds=30):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if check(): return
        time.sleep(0.2)
    raise RuntimeError('Timeout: ' + label)

def record(name, value=True):
    report['checks'][name] = value
    assert value, name
    print('PASS', name, flush=True)

with tempfile.TemporaryDirectory(prefix='lookin-autoconnect-live-') as temporary:
    work = Path(temporary)
    directory = work / 'owner'
    source = ROOT / 'LookinClient/Simulator'
    binary = work / 'host'
    compile_host = run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-framework', 'Cocoa', '-I', source,
        source / 'LKSimulatorAutoConnect.m', ROOT / 'Tests/SimulatorAutoConnectLiveHost.m', '-o', binary])
    assert compile_host.returncode == 0, compile_host.stderr
    wire_source = (ROOT / 'Tests/Performance/wire_client.m').read_text()
    wire_source = wire_source.replace('/Applications/Lookin MCP.app/Contents/Frameworks/LookinShared.framework/LookinShared', str(client / 'Contents/Frameworks/LookinShared.framework/LookinShared'))
    wire_source = wire_source.replace('NSMutableArray *core=[NSMutableArray array]; for(id root in roots)',
        'row[@"bundle"] = [[info valueForKey:@"appInfo"] valueForKey:@"appBundleIdentifier"] ?: @""; row[@"simulatorUDID"] = [[info valueForKey:@"appInfo"] valueForKey:@"simulatorUDID"] ?: @""; NSMutableArray *core=[NSMutableArray array]; for(id root in roots)')
    (work / 'wire.m').write_text(wire_source)
    wire = work / 'wire'
    compile_wire = run(['xcrun', 'clang', '-fobjc-arc', '-Wno-incompatible-pointer-types', '-Wno-deprecated-declarations', '-framework', 'Foundation', '-framework', 'AppKit', work / 'wire.m', '-o', wire])
    assert compile_wire.returncode == 0, compile_wire.stderr
    other_app = work / 'Other.app'
    shutil.copytree(args.fixture, other_app)
    info = plistlib.loads((other_app / 'Info.plist').read_bytes())
    info['CFBundleIdentifier'] = other
    (other_app / 'Info.plist').write_bytes(plistlib.dumps(info))
    signed = run(['codesign', '--force', '--sign', '-', '--preserve-metadata=entitlements', other_app])
    assert signed.returncode == 0, signed.stderr

    def start_host():
        stop = directory / 'stop'
        if stop.exists(): stop.unlink()
        return subprocess.Popen([str(binary), str(directory), str(client / 'Contents/Resources/LookinSimulatorLoader.dylib'), str(server), ','.join(devices)], env=environment,
            stdout=(args.output / 'host.stdout.log').open('a'), stderr=(args.output / 'host.stderr.log').open('a'))

    def ready(device):
        return str(directory / 'loader.dylib') in sim('spawn', device, 'launchctl', 'getenv', 'DYLD_INSERT_LIBRARIES', check=False)

    def launch(device, bundle, expected, label):
        jobs = sim('spawn', device, 'launchctl', 'list').splitlines()
        if any(len(parts) == 3 and parts[0].isdigit() and parts[2].startswith('UIKitApplication:' + bundle + '[')
               for parts in (line.split() for line in jobs)):
            sim('terminate', device, bundle)
        started = time.time()
        launched = sim('launch', device, bundle)
        pid = int(launched.rsplit(':', 1)[1].strip())
        container = Path(sim('get_app_container', device, bundle, 'data'))
        state_file = container / 'Documents/state.json'
        def fresh():
            try:
                state = json.loads(state_file.read_text())
                return state['pid'] == pid and state['timestamp'] >= started and state['applicationState'] == 0
            except (OSError, ValueError): return False
        wait_for(fresh, label)
        state = json.loads(state_file.read_text())
        (args.output / (label + '.json')).write_text(json.dumps(state, indent=2))
        record(label + ': loaded=' + str(expected), bool(state['lookinLoaded']) == expected and state['traced'] == 0)
        if expected:
            ports = run(['lsof', '-nP', '-a', '-p', str(pid), '-iTCP', '-sTCP:LISTEN']).stdout
            port = next(line.split('127.0.0.1:')[1].split()[0] for line in ports.splitlines() if '127.0.0.1:4716' in line)
            result = run([wire, port, '1', 'full'])
            (args.output / (label + '.wire.log')).write_text(result.stdout + result.stderr)
            assert result.returncode == 0, result.stderr
            response = json.loads(result.stdout)
            record(label + ': hierarchy and images', response['bundle'] == bundle and response['simulatorUDID'] == device and response['nodes'] == 5 and response['images'] > 0 and response['failures'] == 0)
        return state

    try:
        for _ in range(2): devices.append(sim('create', 'Lookin AutoConnect Live Test', 'com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro', 'com.apple.CoreSimulator.SimRuntime.iOS-18-6'))
        report['devices'] = devices
        a, b = devices
        sim('boot', a); sim('bootstatus', a, '-b')
        sim('listapps', a)
        sim('install', a, args.fixture.resolve()); sim('install', a, other_app)
        host = start_host()
        wait_for(lambda: ready(a), 'first simulator enabled')
        launch(a, other, False, '01-unselected')
        launch(a, selected, True, '02-selected')
        launch(a, selected, True, '03-relaunch')
        old_container = sim('get_app_container', a, selected, 'app')
        sim('uninstall', a, selected); sim('install', a, args.fixture.resolve())
        record('Reinstall changed container', old_container != sim('get_app_container', a, selected, 'app'))
        launch(a, selected, True, '04-reinstalled')
        sim('boot', b); sim('bootstatus', b, '-b')
        sim('listapps', b)
        wait_for(lambda: ready(b), 'new simulator enabled')
        sim('install', b, args.fixture.resolve())
        launch(b, selected, True, '05-other-simulator')
        sim('shutdown', b); sim('boot', b); sim('bootstatus', b, '-b')
        wait_for(lambda: ready(b), 'rebooted simulator enabled')
        launch(b, selected, True, '06-rebooted-simulator')
        (directory / 'stop').touch(); host.wait(timeout=30); host = None
        record('Normal quit cleans both simulators', not ready(a) and not ready(b))
        launch(a, selected, False, '07-after-desktop-quit')
        host = start_host(); wait_for(lambda: ready(a), 'desktop reopened')
        launch(a, selected, True, '08-desktop-reopened')
        host.kill(); host.wait(timeout=10); host = None
        record('Crash leaves stale environment for gate test', ready(a))
        launch(a, selected, False, '09-after-desktop-crash')
        report['passed'] = True
    finally:
        if host and host.poll() is None:
            (directory / 'stop').touch()
            try: host.wait(timeout=30)
            except subprocess.TimeoutExpired: host.kill(); host.wait()
        for device in devices:
            sim('shutdown', device, check=False)
            sim('delete', device, check=False)
        run(['defaults', 'delete', 'local.lookin.autoconnect.live-test'])
        (args.output / 'report.json').write_text(json.dumps(report, indent=2))
print(json.dumps(report, indent=2))
