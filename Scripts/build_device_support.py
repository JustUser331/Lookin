"""Build the bundled USB helper and device server from pinned local sources."""
from pathlib import Path
import argparse
import os
import shutil
import subprocess


def run(arguments):
    subprocess.run([str(x) for x in arguments], check=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--work', type=Path, required=True)
    args = parser.parse_args()
    source = Path(__file__).resolve().parents[1]
    root = source
    output, work = args.output.resolve(), args.work.resolve()
    output.mkdir(parents=True, exist_ok=True)
    work.mkdir(parents=True, exist_ok=True)
    # Не изменяем vendored sources и не включаем Apple frameworks в дистрибутив.
    vendor = source / 'Vendor/ios-deploy'
    for arch in ['arm64', 'x86_64']:
        run(['xcrun', '--sdk', 'macosx', 'clang', '-arch', arch, '-mmacosx-version-min=13.0',
             '-fno-objc-arc', '-fblocks', '-O2', '-Wno-deprecated-declarations',
             '-F/Library/Apple/System/Library/PrivateFrameworks', '-F/System/Library/PrivateFrameworks',
             '-framework', 'MobileDevice', '-framework', 'Foundation', '-framework', 'CoreFoundation',
             vendor / 'src/ios-deploy/ios-deploy.m', '-o', work / ('ios-deploy-' + arch)])
    run(['xcrun', 'lipo', '-create', work / 'ios-deploy-arm64', work / 'ios-deploy-x86_64', '-output', output / 'ios-deploy'])
    run(['codesign', '--force', '--sign', '-', '--timestamp=none', output / 'ios-deploy'])
    run(['xcodebuild', '-project', root / 'build/ServerBuilder/Pods/Pods.xcodeproj', '-scheme', 'LookinServer',
         '-configuration', 'Release', '-sdk', 'iphoneos', '-destination', 'generic/platform=iOS',
         '-derivedDataPath', work / 'ServerDerivedData', 'SYMROOT=' + str(work / 'ServerProducts'),
         'ARCHS=arm64', 'ONLY_ACTIVE_ARCH=NO', 'CODE_SIGNING_ALLOWED=NO',
         'IPHONEOS_DEPLOYMENT_TARGET=14.0', 'BUILD_LIBRARY_FOR_DISTRIBUTION=YES', 'build'])
    framework = work / 'ServerProducts/Release-iphoneos/LookinServer/LookinServer.framework'
    if (output / framework.name).exists():
        shutil.rmtree(output / framework.name)
    shutil.copytree(framework, output / framework.name)
    # Общая Simulator-библиотека собирается из той же закреплённой ревизии.
    run(['xcodebuild', '-project', root / 'build/ServerBuilder/Pods/Pods.xcodeproj', '-scheme', 'LookinServer',
         '-configuration', 'Release', '-sdk', 'iphonesimulator', '-destination', 'generic/platform=iOS Simulator',
         '-derivedDataPath', work / 'SimulatorDerivedData', 'SYMROOT=' + str(work / 'SimulatorProducts'),
         'ARCHS=arm64 x86_64', 'ONLY_ACTIVE_ARCH=NO', 'CODE_SIGNING_ALLOWED=NO',
         'IPHONEOS_DEPLOYMENT_TARGET=14.0', 'BUILD_LIBRARY_FOR_DISTRIBUTION=YES', 'build'])
    simulator = work / 'SimulatorProducts/Release-iphonesimulator/LookinServer/LookinServer.framework'
    destination = output.parent / 'LookinServer.framework'
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(simulator, destination)
    for file in (source / 'DeviceSupport').glob('*.py'):
        shutil.copy2(file, output / file.name)
    for file in ['LICENSE', 'LICENSE2', 'REVISION']:
        shutil.copy2(vendor / file, output / ('ios-deploy-' + file))
    shutil.copy2(root / 'build/Dependencies/LookinServer/LICENSE', output / 'LookinServer-LICENSE')


if __name__ == '__main__':
    main()
