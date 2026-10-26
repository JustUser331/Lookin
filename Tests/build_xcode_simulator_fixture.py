#!/usr/bin/env python3
"""Generate an isolated Xcode Run fixture with no Lookin link dependency."""
from pathlib import Path
import argparse
import json
import os
import plistlib
import shutil
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--architecture', choices=['universal', 'arm64', 'x86_64'], default='universal')
args = parser.parse_args()
root = args.output.resolve()
root.mkdir(parents=True, exist_ok=True)
source = Path(__file__).with_name('SimulatorAutoConnectFixture.m').read_text()
(root / 'main.m').write_text(source.replace('Lookin without Xcode', 'Lookin Xcode Run'))
(root / 'Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier': '$(PRODUCT_BUNDLE_IDENTIFIER)', 'CFBundleExecutable': '$(EXECUTABLE_NAME)',
    'CFBundleName': 'Lookin Xcode Research', 'CFBundleDisplayName': 'Lookin Xcode Research',
    'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0',
    'LSRequiresIPhoneOS': True, 'MinimumOSVersion': '16.0', 'UIDeviceFamily': [1, 2],
    'UILaunchScreen': {}, 'UISupportedInterfaceOrientations': ['UIInterfaceOrientationPortrait']}))
info = plistlib.loads((root / 'Info.plist').read_bytes())
info['CFBundleURLTypes'] = [{'CFBundleURLName': 'local.lookin.research.xcode', 'CFBundleURLSchemes': ['lookin-xcode-research']}]
(root / 'Info.plist').write_bytes(plistlib.dumps(info))
script = '''require 'xcodeproj'
root = ARGV.fetch(0)
architecture = ARGV.fetch(1)
project = Xcodeproj::Project.new(File.join(root, 'LookinXcodeResearch.xcodeproj'))
target = project.new_target(:application, 'LookinXcodeResearch', :ios, '16.0')
target.source_build_phase.add_file_reference(project.main_group.new_file(File.join(root, 'main.m')))
target.build_configurations.each do |config|
  config.build_settings.merge!({'PRODUCT_BUNDLE_IDENTIFIER' => 'local.lookin.research.xcode',
    'INFOPLIST_FILE' => File.join(root, 'Info.plist'), 'CLANG_ENABLE_OBJC_ARC' => 'YES',
    'SDKROOT' => 'iphonesimulator', 'SUPPORTED_PLATFORMS' => 'iphonesimulator',
    'ARCHS' => architecture, 'ONLY_ACTIVE_ARCH' => 'NO', 'ENABLE_DEBUG_DYLIB' => 'NO',
    'GCC_OPTIMIZATION_LEVEL' => '0', 'CODE_SIGN_IDENTITY' => '-', 'CODE_SIGN_STYLE' => 'Manual'})
end
project.save
scheme = Xcodeproj::XCScheme.new
scheme.configure_with_targets(target, nil)
scheme.launch_action.buildable_product_runnable = Xcodeproj::XCScheme::BuildableProductRunnable.new(target, '0')
scheme.save_as(project.path, 'LookinXcodeResearch', true)
'''
environment = os.environ.copy()
ruby = shutil.which('ruby')
pod = shutil.which('pod')
brew_ruby = Path('/opt/homebrew/opt/ruby/bin/ruby')
if pod and brew_ruby.exists():
    gems = Path(pod).resolve().parents[1] / 'libexec'
    if (gems / 'gems').exists():
        environment['GEM_HOME'] = str(gems)
        defaults = subprocess.check_output([str(brew_ruby), '-e', 'puts Gem.path.join(File::PATH_SEPARATOR)'], text=True).strip()
        environment['GEM_PATH'] = str(gems) + os.pathsep + defaults
        ruby = str(brew_ruby)
architecture = 'arm64 x86_64' if args.architecture == 'universal' else args.architecture
subprocess.run([ruby, '-e', script, str(root), architecture], env=environment, check=True)
print(json.dumps({'project': str(root / 'LookinXcodeResearch.xcodeproj'), 'scheme': 'LookinXcodeResearch',
                  'bundleID': 'local.lookin.research.xcode'}))
