"""Exercise production manager and loader without touching real Simulator devices."""
from pathlib import Path
import fcntl
import os
import plistlib
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'LookinClient/Simulator'

def run(*args, **kwargs):
    return subprocess.run(list(map(str, args)), check=True, **kwargs)

with tempfile.TemporaryDirectory(prefix='lookin-autoconnect-tests-') as temporary:
    work = Path(temporary)
    harness = work / 'manager-tests'
    run('xcrun', 'clang', '-fobjc-arc', '-fblocks', '-Wall', '-Werror', '-framework', 'Foundation',
        '-I', SOURCE, SOURCE / 'LKSimulatorAutoConnect.m', ROOT / 'Tests/SimulatorAutoConnectHarness.m', '-o', harness)
    run(harness, work / 'manager')
    loader = work / 'loader.dylib'
    run('xcrun', 'clang', '-dynamiclib', '-Wall', '-Wextra', '-Werror',
        SOURCE / 'LookinSimulatorLoader.c', '-o', loader)
    dependencies = subprocess.check_output(['otool', '-L', str(loader)], text=True)
    assert 'CoreFoundation' not in dependencies and 'libobjc' not in dependencies, dependencies
    (work / 'main.c').write_text('int main(void) { return 0; }\n')
    (work / 'server.c').write_text('#include <stdio.h>\n#include <stdlib.h>\n__attribute__((constructor)) static void load(void) { FILE *f=fopen(getenv("LOOKIN_TEST_MARKER"),"w"); if(f){fputs("loaded",f);fclose(f);} }\n')
    server = work / 'server.dylib'
    run('xcrun', 'clang', '-dynamiclib', work / 'server.c', '-o', server)
    executable = work / 'fixture'
    run('xcrun', 'clang', work / 'main.c', '-o', executable)
    marker = work / 'loaded'
    env = dict(os.environ, DYLD_INSERT_LIBRARIES=str(loader), LOOKIN_TEST_MARKER=str(marker))
    config = {'enabled': True, 'bundleIDs': ['test.selected'], 'serverPath': str(server)}
    (work / 'config.plist').write_bytes(plistlib.dumps(config))
    owner = (work / 'owner.lock').open('w')
    fcntl.flock(owner, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def launch(name, bundle_id, expected, container='Containers/Bundle/Application/first', suffix='.app'):
        app = work / container / (name + suffix)
        app.mkdir(parents=True, exist_ok=True)
        binary = app / name
        binary.write_bytes(executable.read_bytes())
        binary.chmod(0o755)
        (app / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': bundle_id, 'CFBundleExecutable': name}))
        if marker.exists(): marker.unlink()
        run(binary, env=env)
        assert marker.exists() == expected, (name, bundle_id, expected)

    launch('Selected', 'test.selected', True)
    launch('Unselected', 'test.unselected', False)
    launch('Selected', 'test.selected', True, container='Containers/Bundle/Application/reinstalled')
    launch('System', 'test.selected', False, container='System/Applications')
    launch('Extension', 'test.selected', False, suffix='.appex')
    config['enabled'] = False
    (work / 'config.plist').write_bytes(plistlib.dumps(config))
    launch('Disabled', 'test.selected', False)
    config['enabled'] = True
    (work / 'config.plist').write_bytes(plistlib.dumps(config))
    owner.close()
    launch('AfterDesktopExit', 'test.selected', False)
    (work / 'config.plist').write_text('invalid plist')
    launch('InvalidConfig', 'test.selected', False)
    print('PASS: Production loader bundle filtering, reinstall, system/extension exclusion and desktop lifetime gate')
