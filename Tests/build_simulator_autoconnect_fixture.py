"""Build the dependency-free iOS fixture used by the live auto-connect suite."""
from pathlib import Path
import argparse
import plistlib
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
app = args.output.resolve()
app.mkdir(parents=True, exist_ok=True)
(app / 'Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'local.lookin.research.autoconnect',
    'CFBundleExecutable': 'Research', 'CFBundleName': 'Lookin Research',
    'CFBundleDisplayName': 'Lookin Research', 'CFBundlePackageType': 'APPL',
    'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0',
    'CFBundleSupportedPlatforms': ['iPhoneSimulator'],
    'LSRequiresIPhoneOS': True, 'MinimumOSVersion': '16.0',
    'UIDeviceFamily': [1, 2], 'UILaunchScreen': {},
    'UISupportedInterfaceOrientations': ['UIInterfaceOrientationPortrait']}))
entitlements = app.parent / 'Research.entitlements'
entitlements.write_bytes(plistlib.dumps({'com.apple.security.get-task-allow': True}))
sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
subprocess.run(['xcrun', 'clang', '-target', 'arm64-apple-ios16.0-simulator', '-isysroot', sdk,
    '-fobjc-arc', '-g', '-O0', '-framework', 'UIKit', '-framework', 'Foundation',
    str(Path(__file__).with_name('SimulatorAutoConnectFixture.m')), '-o', str(app / 'Research')], check=True)
subprocess.run(['codesign', '--force', '--sign', '-', '--entitlements', str(entitlements), str(app)], check=True)
print(app)
