#!/usr/bin/env python3
"""Exercise production request lifetimes with a delayed fake PeerTalk transport."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "LookinClient/Connection/LKConnectionManager.m").read_text()
# Copy complete Objective-C methods directly, without rewriting their statements.
public = source[source.index("- (RACSignal *)requestWithType:"):source.index("- (NSError *)_checkServerVersionWithResponse:")]
private = source[source.index("- (RACDisposable *)_requestWithType:"):source.index("- (void)_startListeningForUSBDevices")]
disconnect = source[source.index('- (void)ioFrameChannel:(Lookin_PTChannel*)channel didEndWithError:'):source.rindex('@end')]
with tempfile.TemporaryDirectory(prefix="lookin-connection-tests-") as output:
    work = Path(output)
    (work / "ConnectionMethodsUnderTest.inc").write_text(public + private + disconnect)
    binary = work / "regressions"
    subprocess.run([
        "xcrun", "clang", "-fobjc-arc", "-fblocks", "-Werror",
        "-Wno-nullability-completeness", "-framework", "Foundation", "-I", str(work),
        str(ROOT / "Tests/ConnectionHarness.m"), "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True)
