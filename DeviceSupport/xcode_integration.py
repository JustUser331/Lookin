"""Manage one global Xcode startup breakpoint, preserving other user settings."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent
BREAKPOINT_ID = '8AD81396-3F50-5AC6-9FA0-481AF37773A1'
BREAKPOINT_NAME = 'LookinXcodeAutoConnect'


def locations(home):
    support = home / 'Library/Application Support/LookinMCP/XcodeIntegration'
    breakpoints = home / 'Library/Developer/Xcode/UserData/xcdebugger/Breakpoints_v2.xcbkptlist'
    return support, breakpoints


def atomic_write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix='.lookin-', delete=False) as stream:
        temporary = Path(stream.name)
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
    try:
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def is_owned(proxy):
    content = proxy.find('BreakpointContent')
    return content is not None and content.get('uuid') == BREAKPOINT_ID


def document(path):
    if path.exists():
        root = ET.fromstring(path.read_bytes())
        if root.tag != 'Bucket':
            raise RuntimeError('Unknown Xcode breakpoint format; no settings were changed.')
    else:
        root = ET.Element('Bucket', uuid='UserGlobalBreakpointBucket', type='2', version='2.0')
    entries = root.find('Breakpoints')
    if entries is None:
        entries = ET.SubElement(root, 'Breakpoints')
    return root, entries


def write_breakpoints(path, root, support):
    original = path.read_bytes() if path.exists() else None
    backup = None
    if original is not None:
        backup = support / 'Backups' / ('Breakpoints-' + uuid.uuid4().hex + '.xcbkptlist')
        atomic_write(backup, original)
    ET.indent(root, space='   ')
    atomic_write(path, ET.tostring(root, encoding='utf-8', xml_declaration=True))
    return str(backup) if backup else None


def state(home):
    support, path = locations(home)
    config = json.loads((support / 'config.json').read_text()) if (support / 'config.json').exists() else {}
    root, entries = document(path)
    installed = any(is_owned(p) and p.find('BreakpointContent').get('shouldBeEnabled') == 'Yes' for p in entries)
    result = {'enabled': bool(config.get('enabled') and installed), 'installed': installed, 'supportPath': str(support)}
    if (support / 'last-session.json').exists():
        result['lastSession'] = json.loads((support / 'last-session.json').read_text())
    return result


def enable(home, resources=ROOT, xcode_running=False):
    if xcode_running:
        raise RuntimeError('Quit Xcode once before enabling integration. This prevents Xcode from overwriting its global breakpoint settings. Then enable integration and reopen Xcode; future Runs need no setup.')
    support, path = locations(home)
    root, entries = document(path)
    # Сначала проверяем/готовим ресурсы. Повреждённый XML не заменяется новым файлом.
    for name in ['xcode_bridge.py', 'device_connect.py', 'LookinServer.framework/LookinServer']:
        if not (resources / name).is_file():
            raise RuntimeError('The packaged Xcode integration resources are missing: ' + name)
    support.mkdir(parents=True, exist_ok=True)
    os.chmod(support, 0o700)
    for name in ['xcode_bridge.py', 'device_connect.py']:
        atomic_write(support / name, (resources / name).read_bytes())
    server = support / 'LookinServer.framework'
    staging = support / ('server-' + uuid.uuid4().hex)
    shutil.copytree(resources / 'LookinServer.framework', staging)
    if server.exists():
        shutil.rmtree(server)
    staging.rename(server)
    for proxy in list(entries):
        if is_owned(proxy):
            entries.remove(proxy)
    proxy = ET.SubElement(entries, 'BreakpointProxy', BreakpointExtensionID='Xcode.Breakpoint.SymbolicBreakpoint')
    content = ET.SubElement(proxy, 'BreakpointContent', uuid=BREAKPOINT_ID, shouldBeEnabled='Yes',
                            nameForDebugger=BREAKPOINT_NAME, ignoreCount='0', continueAfterRunningActions='Yes',
                            symbolName='UIApplicationMain', moduleName='')
    actions = ET.SubElement(content, 'Actions')
    script = str(support / 'xcode_bridge.py')
    command = 'command script import -r ' + '"' + script.replace('\\', '\\\\').replace('"', '\\"') + '"'
    for text in [command, 'lookin-xcode-load']:
        action = ET.SubElement(actions, 'BreakpointActionProxy', ActionExtensionID='Xcode.BreakpointAction.DebuggerCommand')
        ET.SubElement(action, 'ActionContent', consoleCommand=text)
    ET.SubElement(content, 'Locations')
    backup = write_breakpoints(path, root, support)
    atomic_write(support / 'config.json', json.dumps({'enabled': True}).encode())
    return dict(state(home), backup=backup, message='Enabled. Reopen Xcode and use Run as usual. Then select the app in Lookin.')


def disable(home, xcode_running=False):
    support, path = locations(home)
    atomic_write(support / 'config.json', json.dumps({'enabled': False}).encode())
    if not xcode_running:
        root, entries = document(path)
        owned = [p for p in entries if is_owned(p)]
        for p in owned:
            entries.remove(p)
        if owned:
            write_breakpoints(path, root, support)
    return dict(state(home), message='Disabled. Future launches will not load LookinServer. An already loaded server remains until its app exits.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['status', 'enable', 'disable'])
    args = parser.parse_args()
    try:
        home = Path.home()
        if args.command == 'status':
            result = state(home)
        else:
            check = subprocess.run(['/usr/bin/pgrep', '-x', 'Xcode'], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            if check.returncode not in (0, 1):
                raise RuntimeError('Unable to determine whether Xcode is running; breakpoint settings were not changed.')
            running = check.returncode == 0
            result = enable(home, xcode_running=running) if args.command == 'enable' else disable(home, xcode_running=running)
        print(json.dumps(result, ensure_ascii=False))
    except Exception as error:
        print(json.dumps({'success': False, 'error': str(error)}, ensure_ascii=False))
        raise SystemExit(1)


if __name__ == '__main__':
    main()
