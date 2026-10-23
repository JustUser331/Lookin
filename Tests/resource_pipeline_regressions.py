"""Compile production decode/apply methods against a delayed transport boundary."""
from pathlib import Path
import subprocess
import tempfile

root=Path(__file__).resolve().parents[1]
source=(root/'LookinClient/Connection/LKConnectionManager.m').read_text()
frameworks=root/'build/ClientDerivedData/Build/Products/Release/LookinShared'
connection=root/'LookinClient/Connection'
with tempfile.TemporaryDirectory(prefix='lookin-resource-pipeline-') as temporary:
    work=Path(temporary)
    (work/'ResourceResponseClass.inc').write_text(source[source.index('@interface LKQueuedResourceResponse'):source.index('static NSIndexSet')])
    (work/'ResourcePipelineMethods.inc').write_text(source[source.index('- (void)enqueueResourceData:'):source.index('- (void)ioFrameChannel:(Lookin_PTChannel*)channel didEndWithError:')])
    binary=work/'regressions'
    subprocess.run(['xcrun','clang','-O2','-fobjc-arc','-fblocks','-DSHOULD_COMPILE_LOOKIN_SERVER=1','-Wno-incompatible-pointer-types',
                    '-F',str(frameworks),'-framework','LookinShared','-framework','AppKit','-framework','QuartzCore',
                    '-Wl,-rpath,'+str(frameworks),'-I',str(work),'-I',str(connection),str(connection/'LKConnectionRequest.m'),
                    str(Path(__file__).with_name('ResourcePipelineHarness.m')),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
