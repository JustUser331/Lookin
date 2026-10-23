#!/usr/bin/env python3
"""Compile the production preview image selection and Swift cache together."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'LookinClient/Static/Preview/LKDisplayItemNode.m').read_text()
begin = source.index('    BOOL needsImage =')
end = source.index('    NSAssert(MAX(appropriateScreenshot.', begin)
sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
with tempfile.TemporaryDirectory(prefix='lookin-preview-cache-') as directory:
    output = Path(directory)
    (output / 'ImageSelection.inc').write_text(source[begin:end])
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-O', '-emit-library',
        '-sdk', sdk, '-module-cache-path', str(output / 'ModuleCache'),
        '-module-name', 'LookinPreviewSupport', '-emit-objc-header',
        '-emit-objc-header-path', str(output / 'LookinPreviewSupport-Swift.h'),
        str(ROOT / 'ResourceCore/Sources/LookinPreviewSupport/PreviewImageCache.swift'),
        '-o', str(output / 'libLookinPreviewSupport.dylib')], check=True)
    binary = output / 'regressions'
    subprocess.run(['xcrun', 'clang', '-O2', '-fobjc-arc', '-fblocks', '-Werror',
        '-isysroot', sdk, '-framework', 'Cocoa', '-I', str(output), '-L', str(output),
        '-lLookinPreviewSupport', '-Wl,-rpath,' + str(output),
        str(ROOT / 'Tests/PreviewImageCacheHarness.m'), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
