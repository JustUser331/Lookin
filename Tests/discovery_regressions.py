#!/usr/bin/env python3
"""Run production port discovery against missing, delayed and recovering peers."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
frameworks = root / 'build/ClientDerivedData/Build/Products/Release/ReactiveObjC'
source = (root / 'LookinClient/Connection/LKConnectionManager.m').read_text()
methods = source[source.index('- (RACSignal *)tryToConnectAllPorts {'):source.index('#pragma mark - Request')]
launch = (root / 'LookinClient/Launch/LKLaunchViewController.m').read_text()
reload = launch[launch.index('- (void)_reloadWithAutoEntering:'):launch.index('- (void)_handleClickAppView:')]
apps = (root / 'LookinClient/Connection/LKAppsManager.m').read_text()
probes = apps[apps.index('- (RACSignal *)fetchAppInfosWithImage:'):apps.rindex('@end')]
with tempfile.TemporaryDirectory(prefix='lookin-discovery-') as directory:
    work = Path(directory)
    (work / 'Discovery.inc').write_text(methods)
    (work / 'DiscoveryLoop.inc').write_text(reload)
    (work / 'AppInfoProbe.inc').write_text(probes)
    binary = work / 'test'
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-Werror', '-Wno-nullability-completeness',
                    '-framework', 'Foundation', '-F', str(frameworks), '-framework', 'ReactiveObjC',
                    '-Wl,-rpath,' + str(frameworks), '-I', str(work), str(root / 'Tests/DiscoveryHarness.m'),
                    '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
