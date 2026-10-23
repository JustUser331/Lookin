#!/usr/bin/env python3
"""Compile production coordinator with deterministic fake transport; never opens UI."""
from pathlib import Path
import argparse
import os
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "LookinClient/Static/LKStaticAsyncUpdateManager"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source-m', type=Path, default=SOURCE.with_suffix('.m'))
parser.add_argument('--benchmark-old-response', action='store_true')
args = parser.parse_args()


def without_imports(path):
    return re.sub(r"^(?:#import[^\n]*|@import[^\n]*)\n", "", path.read_text(), flags=re.MULTILINE)


with tempfile.TemporaryDirectory(prefix="lookin-coordinator-tests-") as output:
    work = Path(output)
    uses_swift = '@import LookinResourceCore;' in args.source_m.read_text()
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    libraries = []
    if uses_swift:
        swift_sources = sorted((ROOT / 'ResourceCore/Sources/LookinResourceCore').glob('*.swift'))
        subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-O', '-emit-library',
                        '-sdk', sdk, '-module-cache-path', str(work / 'ModuleCache'),
                        '-module-name', 'LookinResourceCore', '-emit-objc-header',
                        '-emit-objc-header-path', str(work / 'LookinResourceCore-Swift.h'),
                        *map(str, swift_sources), '-o', str(work / 'libLookinResourceCore.dylib')], check=True)
        libraries = ['-L', str(work), '-lLookinResourceCore', '-Wl,-rpath,' + str(work)]
        (work / 'SwiftCoreUnderTest.inc').write_text('#import "LookinResourceCore-Swift.h"\n')
    else:
        (work / 'SwiftCoreUnderTest.inc').write_text('')
    selection = (ROOT / "LookinClient/Base/Category/LookinDisplayItem+LookinClient.m").read_text()
    (work / "ScreenshotSelectionUnderTest.inc").write_text(
        selection[selection.index("- (BOOL)hasPhysicalSublayers"):selection.index("- (BOOL)isUserCustom")]
    )
    (work / "CoordinatorUnderTest.inc").write_text(
        without_imports(SOURCE.with_suffix(".h"))
        + "\n"
        + without_imports(args.source_m)
    )
    binary = work / "regressions"
    subprocess.run([
        "xcrun", "clang", "-fobjc-arc", "-fblocks", "-Werror",
        *(['-O2'] if os.environ.get('HC_PLANNER_BENCHMARK') else []),
        "-isysroot", sdk,
        "-Wno-nullability-completeness", "-Wno-objc-root-class", "-Wno-incompatible-pointer-types",
        "-framework", "Cocoa", "-I", str(work),
        *libraries,
        str(ROOT / "Tests/CoordinatorHarness.m"), "-o", str(binary),
    ], check=True)
    environment = dict(os.environ)
    if args.benchmark_old_response:
        environment['HC_RESPONSE_BENCHMARK_ONLY'] = '1'
    subprocess.run([str(binary)], check=True, env=environment)
