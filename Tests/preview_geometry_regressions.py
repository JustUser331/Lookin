"""Compare production Z methods against the revision before geometry caching."""
from pathlib import Path
import subprocess
import tempfile

root=Path(__file__).resolve().parents[1]
relative='LookinClient/Static/Preview/LKPreviewView.m'
before=(root/'Tests/Fixtures/PreviewGeometryBaseline.inc').read_text()
after=(root/relative).read_text()
formula=(root/'LookinClient/Base/Category/LookinDisplayItem+LookinClient.m').read_text()
frameworks=root/'build/ClientDerivedData/Build/Products/Release/LookinShared'
def methods(source):
    first=source[source.index('- (void)updateZPosition {'):source.index('- (void)_updateZPositionByZIndex {')]
    rest=source[source.index('- (void)_updateZIndexForItem:'):source.index('- (void)didSelectItem:')]
    return first+rest
with tempfile.TemporaryDirectory(prefix='lookin-preview-geometry-') as temporary:
    work=Path(temporary)
    (work/'GeometryBefore.inc').write_text(before)
    (work/'GeometryAfter.inc').write_text(methods(after))
    (work/'FrameFormula.inc').write_text(formula[formula.index('- (CGRect)calculateFrameToRoot {'):formula.index('- (BOOL)isMatchedWithSearchString:')])
    binary=work/'regressions'
    subprocess.run(['xcrun','clang','-O2','-fobjc-arc','-fblocks','-DSHOULD_COMPILE_LOOKIN_SERVER=1','-Wno-incompatible-pointer-types',
                    '-F',str(frameworks),'-framework','LookinShared','-framework','AppKit','-Wl,-rpath,'+str(frameworks),'-I',str(work),
                    str(Path(__file__).with_name('PreviewGeometryHarness.m')),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
