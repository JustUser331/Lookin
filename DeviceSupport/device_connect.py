"""USB device connection without modifying the inspected application's bundle."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parent


def run(args, timeout=45, check=True):
    # Не используем shell: пути и имена приложений не являются командами.
    process = subprocess.Popen([str(x) for x in args], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               start_new_session=True)
    try:
        out, err = process.communicate(timeout=timeout)
    except BaseException:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.communicate(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
        raise
    output = out.decode('utf-8', errors='replace')
    errors = err.decode('utf-8', errors='replace')
    if check and process.returncode:
        raise RuntimeError((errors + '\n' + output)[-5000:].strip() or 'Device command failed.')
    return process.returncode, output, errors


def json_objects(text):
    decoder = json.JSONDecoder()
    result = []
    while text.strip():
        text = text.lstrip()
        value, end = decoder.raw_decode(text)
        result.append(value)
        text = text[end:]
    return result


def devices():
    code, output, error = run([ROOT / 'ios-deploy', '--detect', '--json', '--no-wifi', '--timeout', '3'], timeout=15, check=False)
    if code not in (0, 253):
        raise RuntimeError(error or 'USB discovery failed. Unlock the device and trust this Mac.')
    rows = []
    for event in json_objects(output):
        if event.get('Event') != 'DeviceDetected' or event.get('Interface') != 'USB':
            continue
        item = event.get('Device', {})
        if item.get('DeviceClass') not in ('iPhone', 'iPad'):
            continue
        version = item.get('ProductVersion', '')
        major = int(version.split('.')[0]) if version else 0
        rows.append({'id': item['DeviceIdentifier'], 'name': item.get('DeviceName', 'iOS device'),
                     'model': item.get('modelName', item.get('ProductType', '')), 'osVersion': version,
                     'supported': 14 <= major <= 16})
    return rows


def read_plist_output(text):
    start = text.find('<?xml')
    if start < 0:
        raise RuntimeError('The app has no readable development entitlements.')
    return plistlib.loads(text[start:text.index('</plist>', start) + 8].encode())


def inspect_app(path, require_debugger_safe_path=True):
    app = Path(path).expanduser().resolve()
    if app.suffix != '.app' or not app.is_dir():
        raise RuntimeError('Choose a built, development-signed iOS .app (not an IPA or Xcode project).')
    if require_debugger_safe_path and any(character in str(app) for character in ['"', "'", '\\', '\n', '\r']):
        raise RuntimeError('Move the .app to a path without quotes, backslashes or newlines before using the debugger.')
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    bundle = info.get('CFBundleIdentifier', '')
    if not re.fullmatch(r'[A-Za-z0-9.-]+', bundle):
        raise RuntimeError('Invalid application bundle identifier.')
    executable = info.get('CFBundleExecutable', '')
    if not executable or Path(executable).name != executable or not (app / executable).is_file():
        raise RuntimeError('Invalid application executable.')
    if 'iPhoneOS' not in info.get('CFBundleSupportedPlatforms', []):
        raise RuntimeError('This is not an iPhoneOS build. Choose the app from Debug-iphoneos.')
    run(['codesign', '--verify', '--deep', '--strict', app])
    _, out, err = run(['codesign', '-d', '--entitlements', ':-', app])
    entitlements = read_plist_output(out + err)
    if entitlements.get('get-task-allow') is not True:
        raise RuntimeError('This app is not debuggable. Use a development build with get-task-allow enabled.')
    return app, bundle, entitlements


def signing_identity(app):
    with tempfile.TemporaryDirectory(prefix='lookin-certificate-') as folder:
        prefix = Path(folder) / 'certificate'
        run(['codesign', '-d', '--extract-certificates=' + str(prefix), app])
        fingerprint = hashlib.sha1(Path(str(prefix) + '0').read_bytes()).hexdigest().upper()
    _, output, _ = run(['security', 'find-identity', '-v', '-p', 'codesigning'])
    valid = re.findall(r'^\s*\d+\) ([0-9A-F]{40}) "[^"\n]+"\s*$', output, re.MULTILINE)
    if fingerprint not in valid:
        raise RuntimeError('The signing certificate and private key used for this app are not available on this Mac. Choose a build signed by an available development identity.')
    return fingerprint


def connect(args):
    if not re.fullmatch(r'[A-Fa-f0-9-]{16,64}', args.device):
        raise RuntimeError('Invalid device identifier.')
    found = next((d for d in devices() if d['id'] == args.device), None)
    if not found:
        raise RuntimeError('The selected USB device is unavailable. Unlock it and trust this Mac.')
    if not found['supported']:
        raise RuntimeError('This connection helper supports iOS 14–16. iOS 17 and later require a different debugger transport.')
    app, bundle, entitlements = inspect_app(args.app)
    identity = signing_identity(app)
    base = [ROOT / 'ios-deploy', '--id', args.device, '--no-wifi']
    code, _, _ = run(base + ['--bundle_id', bundle, '--exists', '--timeout', '15'], check=False)
    if code:
        raise RuntimeError('Install this development app on the selected device with Xcode first. Lookin does not install or replace applications.')
    _, processes, _ = run(base + ['--bundle_id', bundle, '--get_pid', '--json', '--timeout', '20'])
    pid = next((row.get('pid', 0) for row in json_objects(processes) if row.get('Event') == 'GetPid'), 0) or 0
    pid = max(0, int(pid))
    if args.mode == 'attach' and not pid:
        raise RuntimeError('The application is not running. Open it on the device, or choose Launch.')
    if args.mode == 'launch' and pid:
        raise RuntimeError('The application is already running. Choose Attach, or stop it first. Lookin does not terminate your app automatically.')
    session = uuid.uuid4().hex
    folder = Path(tempfile.mkdtemp(prefix='lookin-device-'))
    os.chmod(folder, 0o700)
    server = folder / 'LookinServer.framework'
    shutil.copytree(ROOT / 'LookinServer.framework', server, symlinks=True)
    run(['codesign', '--force', '--sign', identity, '--timestamp=none', server])
    run(['codesign', '--verify', '--strict', server])
    # Не перезаписываем библиотеку, которую уже отображает работающий процесс.
    remote_folder = '/Documents/.lookin-mcp/' + session + '/LookinServer.framework'
    remote = remote_folder.lstrip('/') + '/LookinServer'
    run(base + ['--bundle_id', bundle, '--upload', server, '--to', remote_folder, '--timeout', '30'])
    config = {'session': session, 'bundleID': bundle, 'remotePath': remote, 'mode': args.mode,
              'report': str(folder / 'runtime.json'), 'pid': int(pid)}
    script = folder / 'device_lldb.py'
    script.write_text('LOOKIN_CONFIG = ' + repr(config) + '\n' + (ROOT / 'device_lldb.py').read_text())
    module = 'fruitstrap_' + args.device.replace('-', '_')
    command = base + ['--bundle', app, '--noinstall', '--debug', '--nostart', '--custom-script', script,
                     '--custom-command', 'command script add -s asynchronous -f ' + module + '.lookin_connect lookin_connect',
                     '--custom-command', 'lookin_connect', '--custom-command', 'quit', '--timeout', '150']
    code, output, error = run(command, timeout=170, check=False)
    (folder / 'connection.log').write_text(output + error)
    report_path = folder / 'runtime.json'
    report = json.loads(report_path.read_text()) if report_path.exists() else {}
    if not report.get('success'):
        detail = report.get('error') or ('Unlock the device, stop debugging this app in Xcode, and retry. ' + (output + error)[-1800:])
        raise RuntimeError(detail + '\nLog: ' + str(folder / 'connection.log'))
    return {'success': True, 'bundleID': bundle, 'session': report.get('session', session), 'device': found,
            'mode': args.mode, 'log': str(folder / 'connection.log'), 'runtime': report}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('list')
    connection = commands.add_parser('connect')
    connection.add_argument('--device', required=True)
    connection.add_argument('--app', required=True)
    connection.add_argument('--mode', choices=['launch', 'attach'], default='launch')
    args = parser.parse_args()
    try:
        result = {'devices': devices()} if args.command == 'list' else connect(args)
        print(json.dumps(result, ensure_ascii=False), flush=True)
    except Exception as error:
        print(json.dumps({'success': False, 'error': str(error)}, ensure_ascii=False), flush=True)
        raise SystemExit(1)


if __name__ == '__main__':
    main()
