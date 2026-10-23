"""Exercise production debugger coordination with an already-stopped attach result."""
from pathlib import Path
from types import SimpleNamespace
import json
import tempfile
import time
import unittest


class Success:
    def Fail(self): return False
    def Success(self): return True
    def __str__(self): return 'success'


class Value:
    def __init__(self, value=1, summary=None): self.value,self.summary=value,summary
    def GetError(self): return Success()
    def GetValueAsUnsigned(self): return self.value
    def GetValueAsSigned(self): return self.value
    def GetSummary(self): return self.summary


class Options:
    def __getattr__(self,name): return lambda *args:None


class DebuggerTests(unittest.TestCase):
    def exercise(self, matches=True, reused=True):
        expressions=[]
        def evaluate(expression, options):
            expressions.append(expression)
            if 'isEqualToString:' in expression:return Value(int(matches))
            if 'applicationState' in expression:return Value(0)
            if 'getenv' in expression:return Value(1,json.dumps('a'*32))
            if expression == '(void *)objc_getClass("Lookin")':return Value(int(reused))
            if '_handleApplicationDidBecomeActive' in expression:self.assertTrue(expression.endswith(', 1)'))
            return Value(1)
        frame=SimpleNamespace(EvaluateExpression=evaluate)
        thread=SimpleNamespace(GetFrameAtIndex=lambda i:frame)
        detached=[]
        process=SimpleNamespace(GetState=lambda:5,GetNumThreads=lambda:1,GetThreadAtIndex=lambda i:thread,
            SetSelectedThread=lambda t:None,GetProcessID=lambda:123,IsValid=lambda:True,
            Detach=lambda:(detached.append(True) or Success()))
        module=SimpleNamespace(SetPlatformFileSpec=lambda path:None)
        target=SimpleNamespace(GetModuleAtIndex=lambda i:module,GetNumModules=lambda:0,Attach=lambda info,error:process)
        lldb=SimpleNamespace(SBFileSpec=lambda path:path,SBError=Success,SBAttachInfo=lambda pid:pid,
            SBExpressionOptions=Options,eLanguageTypeObjC_plus_plus=1,eStateStopped=5,eStateExited=10,eStateDetached=9)
        listener=SimpleNamespace(WaitForEvent=lambda *args: self.fail('Attach already stopped; waiting would discard its state.'))
        with tempfile.TemporaryDirectory() as folder:
            report=Path(folder)/'report.json'
            context={'LOOKIN_CONFIG':{'mode':'attach','pid':123,'bundleID':'local.fixture','session':'b'*32,'report':str(report),'remotePath':'Documents/.lookin-mcp/test/LookinServer.framework/LookinServer'},
                     'lldb':lldb,'listener':listener,'time':time}
            source=Path(__file__).resolve().parents[1]/'DeviceSupport/device_lldb.py'
            exec(compile(source.read_text(),str(source),'exec'),context)
            context['lookin_connect'](SimpleNamespace(GetSelectedTarget=lambda:target),'',None,{'fruitstrap_device_app':'/app'})
            result=json.loads(report.read_text())
        self.assertEqual(detached,[True])
        self.assertEqual(any('dlopen' in e for e in expressions), matches and not reused)
        return result

    def test_attach_reuses_existing_server_without_waiting(self):
        result=self.exercise()
        self.assertTrue(result['success'])
        self.assertEqual(result['session'],'a'*32)

    def test_fresh_attach_activates_server_with_explicit_expression_result(self):
        self.assertTrue(self.exercise(reused=False)['success'])

    def test_wrong_bundle_never_injects_and_detaches(self):
        result=self.exercise(False)
        self.assertFalse(result['success'])
        self.assertIn('different application',result['error'])


if __name__=='__main__':unittest.main()
