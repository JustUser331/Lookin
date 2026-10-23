"""Check one-time setup preservation and operation inside an existing debugger."""
from pathlib import Path
from types import SimpleNamespace
import importlib.util
import json
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

source = Path(__file__).resolve().parents[1] / 'DeviceSupport'

def module(name):
    spec=importlib.util.spec_from_file_location(name,source/(name+'.py'))
    result=importlib.util.module_from_spec(spec);spec.loader.exec_module(result);return result

installer=module('xcode_integration');bridge=module('xcode_bridge')

class IntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name);self.home=self.root/'home'
        self.resources=self.root/'resources';self.resources.mkdir()
        for name in ['xcode_bridge.py','device_connect.py']:(self.resources/name).write_text('# fixture')
        server=self.resources/'LookinServer.framework';server.mkdir();(server/'LookinServer').write_bytes(b'fixture')
        self.support,self.breakpoints=installer.locations(self.home)
        self.breakpoints.parent.mkdir(parents=True)
        self.original=b'<Bucket uuid="UserGlobalBreakpointBucket" type="2" version="2.0"><Breakpoints><BreakpointProxy><BreakpointContent uuid="user-owned" shouldBeEnabled="No" nameForDebugger="LookinIntegration" custom="preserve"/></BreakpointProxy></Breakpoints></Bucket>'
        self.breakpoints.write_bytes(self.original)
    def tearDown(self):self.temp.cleanup()
    def test_enable_is_idempotent_and_preserves_other_breakpoints(self):
        result=installer.enable(self.home,self.resources)
        self.assertEqual(Path(result['backup']).read_bytes(),self.original)
        installer.enable(self.home,self.resources)
        root=ET.fromstring(self.breakpoints.read_bytes());proxies=root.find('Breakpoints')
        self.assertEqual(len(proxies),2)
        self.assertEqual(proxies[0].find('BreakpointContent').get('custom'),'preserve')
        own=next(x for x in proxies if installer.is_owned(x));content=own.find('BreakpointContent')
        self.assertEqual(content.get('continueAfterRunningActions'),'Yes')
        actions=content.find('Actions');self.assertEqual(len(actions),2)
        self.assertIn('command script import -r',actions[0].find('ActionContent').get('consoleCommand'))
        self.assertEqual(actions[1].find('ActionContent').get('consoleCommand'),'lookin-xcode-load')
        self.assertTrue(installer.state(self.home)['enabled'])
    def test_running_xcode_is_not_overwritten(self):
        with self.assertRaisesRegex(RuntimeError,'Quit Xcode'):
            installer.enable(self.home,self.resources,xcode_running=True)
        self.assertEqual(self.breakpoints.read_bytes(),self.original)
    def test_disable_while_running_is_immediate_and_keeps_cached_command_valid(self):
        installer.enable(self.home,self.resources)
        before=self.breakpoints.read_bytes()
        result=installer.disable(self.home,xcode_running=True)
        self.assertFalse(result['enabled']);self.assertEqual(self.breakpoints.read_bytes(),before)
        self.assertTrue((self.support/'xcode_bridge.py').exists())
        installer.disable(self.home)
        self.assertEqual(len(ET.fromstring(self.breakpoints.read_bytes()).find('Breakpoints')),1)
    def test_corrupt_settings_are_not_replaced(self):
        self.breakpoints.write_bytes(b'<broken')
        with self.assertRaises(ET.ParseError):installer.enable(self.home,self.resources)
        self.assertEqual(self.breakpoints.read_bytes(),b'<broken')

class Value:
    def __init__(self,value=1,summary=None):self.value=value;self.summary=summary
    def GetError(self):return SimpleNamespace(Fail=lambda:False)
    def GetValueAsUnsigned(self):return self.value
    def GetValueAsSigned(self):return self.value
    def GetSummary(self):return self.summary

class ExistingDebuggerTests(unittest.TestCase):
    def test_system_function_ignores_unloaded_imports(self):
        invalid=(1 << 64)-1
        def context(address):
            return SimpleNamespace(GetSymbol=lambda:SimpleNamespace(GetStartAddress=lambda:SimpleNamespace(GetLoadAddress=lambda target:address)))
        target=SimpleNamespace(FindSymbols=lambda name:[context(invalid),context(0),context(4096),context(4096)])
        self.assertEqual(bridge.function_pointer(target,SimpleNamespace(LLDB_INVALID_ADDRESS=invalid),'close','int (*)(int)'),
                         '((int (*)(int))0x1000)')
        for addresses in [[],[context(invalid)],[context(4096),context(8192)]]:
            target.FindSymbols=lambda name:addresses
            with self.assertRaisesRegex(RuntimeError,'unambiguous'):
                bridge.function_pointer(target,SimpleNamespace(LLDB_INVALID_ADDRESS=invalid),'close','int (*)(int)')

    def test_command_can_be_registered_again_in_same_debugger(self):
        commands=[]
        getattr(bridge, '__lldb_init_module')(SimpleNamespace(HandleCommand=commands.append),{})
        self.assertIn('command script add --overwrite -f',commands[0])

    def test_loader_does_not_launch_stop_continue_or_detach(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);(root/'config.json').write_text('{"enabled":true}')
            app=root/'Any App.app';app.mkdir();(app/'Info.plist').write_text('fixture')
            payload=root/'LookinServer.framework';payload.mkdir();(payload/'LookinServer').write_bytes(b'fixture')
            commands=[];loaded=[False]
            def evaluate(expression,options):
                commands.append(expression)
                # На пользовательском приложении вызов этого селектора из LLDB падает.
                if '] bundleIdentifier]' in expression:
                    raise RuntimeError('EXC_BAD_ACCESS')
                if expression=='(void *)objc_getClass("Lookin")':return Value(int(loaded[0]))
                if 'dlopen' in expression:loaded[0]=True
                return Value()
            process=SimpleNamespace(IsValid=lambda:True,GetState=lambda:5,GetProcessID=lambda:42,
                GetSelectedThread=lambda:SimpleNamespace(GetFrameAtIndex=lambda i:SimpleNamespace(EvaluateExpression=evaluate)),
                ReadCStringFromMemory=lambda *a:'/var/mobile/Containers/Data/Application/fixture')
            target=SimpleNamespace(IsValid=lambda:True,GetExecutable=lambda:str(app/'Executable'),
                GetPlatform=lambda:SimpleNamespace(GetName=lambda:'remote-ios'),GetProcess=lambda:process)
            options=SimpleNamespace(**{name:lambda *a:None for name in ['SetLanguage','SetTimeoutInMicroSeconds','SetIgnoreBreakpoints','SetUnwindOnError']})
            lldb=SimpleNamespace(eStateStopped=5,eLanguageTypeObjC_plus_plus=1,SBExpressionOptions=lambda:options,SBError=lambda:SimpleNamespace(Fail=lambda:False))
            transfer=SimpleNamespace(upload=lambda *a:None,close=lambda:None)
            tools=SimpleNamespace(inspect_app=lambda path,**k:(path,'local.fixture',{}))
            with patch.object(bridge,'ROOT',root),patch.object(bridge,'tools_module',return_value=tools),patch.object(bridge,'signed_payload',return_value=payload),patch.object(bridge,'RemoteFiles',return_value=transfer),patch.dict('sys.modules',{'lldb':lldb}):
                bridge.load(SimpleNamespace(GetSelectedTarget=lambda:target),'',SimpleNamespace(AppendMessage=lambda s:None),{})
            report=json.loads((root/'last-session.json').read_text())
            self.assertTrue(report['success']);self.assertTrue(report['debuggerPreserved']);self.assertEqual(report['pid'],42)
            self.assertTrue(any('dlopen' in c for c in commands))
            self.assertTrue(any('objectForInfoDictionaryKey:@"CFBundleIdentifier"' in c for c in commands))
            self.assertEqual(report['localApp'],str(app))

    def test_mismatched_application_is_rejected_before_signing(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);(root/'config.json').write_text('{"enabled":true}')
            app=root/'Fixture.app';app.mkdir();(app/'Info.plist').write_text('fixture')
            process=SimpleNamespace(IsValid=lambda:True,GetState=lambda:5,GetProcessID=lambda:42,
                GetSelectedThread=lambda:SimpleNamespace(GetFrameAtIndex=lambda i:SimpleNamespace(EvaluateExpression=lambda *a:Value(0))))
            target=SimpleNamespace(IsValid=lambda:True,GetExecutable=lambda:str(app/'Executable'),
                GetPlatform=lambda:SimpleNamespace(GetName=lambda:'remote-ios'),GetProcess=lambda:process)
            options=SimpleNamespace(**{name:lambda *a:None for name in ['SetLanguage','SetTimeoutInMicroSeconds','SetIgnoreBreakpoints','SetUnwindOnError']})
            lldb=SimpleNamespace(eStateStopped=5,eLanguageTypeObjC_plus_plus=1,SBExpressionOptions=lambda:options)
            tools=SimpleNamespace(inspect_app=lambda path,**k:(path,'local.fixture',{}))
            with patch.object(bridge,'ROOT',root),patch.object(bridge,'tools_module',return_value=tools),patch.object(bridge,'signed_payload') as signing,patch.dict('sys.modules',{'lldb':lldb}):
                bridge.load(SimpleNamespace(GetSelectedTarget=lambda:target),'',SimpleNamespace(AppendMessage=lambda s:None),{})
                signing.assert_not_called()
            report=json.loads((root/'last-session.json').read_text())
            self.assertFalse(report['success']);self.assertIn('does not match',report['error'])
    def test_repeated_startup_preserves_existing_session(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);(root/'config.json').write_text('{"enabled":true}')
            app=root/'Fixture.app';app.mkdir();(app/'Info.plist').write_text('fixture')
            def evaluate(expression,options):
                return Value(1,json.dumps('a'*32)) if 'getenv' in expression else Value(1)
            process=SimpleNamespace(IsValid=lambda:True,GetState=lambda:5,GetProcessID=lambda:42,
                GetSelectedThread=lambda:SimpleNamespace(GetFrameAtIndex=lambda i:SimpleNamespace(EvaluateExpression=evaluate)))
            target=SimpleNamespace(IsValid=lambda:True,GetExecutable=lambda:str(app/'Executable'),
                GetPlatform=lambda:SimpleNamespace(GetName=lambda:'remote-ios'),GetProcess=lambda:process)
            options=SimpleNamespace(**{name:lambda *a:None for name in ['SetLanguage','SetTimeoutInMicroSeconds','SetIgnoreBreakpoints','SetUnwindOnError']})
            lldb=SimpleNamespace(eStateStopped=5,eLanguageTypeObjC_plus_plus=1,SBExpressionOptions=lambda:options)
            tools=SimpleNamespace(inspect_app=lambda path,**k:(path,'local.fixture',{}))
            with patch.object(bridge,'ROOT',root),patch.object(bridge,'tools_module',return_value=tools),patch.object(bridge,'signed_payload') as signing,patch.dict('sys.modules',{'lldb':lldb}):
                bridge.load(SimpleNamespace(GetSelectedTarget=lambda:target),'',SimpleNamespace(AppendMessage=lambda s:None),{})
                signing.assert_not_called()
            report=json.loads((root/'last-session.json').read_text())
            self.assertTrue(report['alreadyLoaded']);self.assertTrue(report['success']);self.assertEqual(report['session'],'a'*32)

    def test_remote_upload_handles_partial_writes_and_sets_permissions(self):
        import re
        with tempfile.TemporaryDirectory() as temporary:
            local=Path(temporary)/'LookinServer';local.write_bytes(b'abcdef')
            memory=[b''];written=bytearray();expressions=[]
            def evaluate(expression):
                expressions.append(expression)
                if 'createDirectoryAtPath' in expression:return Value(1)
                if 'open)' in expression:return Value(3)
                if 'write(' in expression:
                    address,count=re.search(r'0x([0-9a-f]+), (\d+)',expression).groups()
                    offset=int(address,16)-4096;size=min(2,int(count))
                    written.extend(memory[0][offset:offset+size]);return Value(size)
                return Value(0)
            def write(address,data,error):memory[0]=data;return len(data)
            error=lambda:SimpleNamespace(Fail=lambda:False)
            process=SimpleNamespace(AllocateMemory=lambda *a:4096,WriteMemory=write,DeallocateMemory=lambda p:error())
            lldb=SimpleNamespace(SBError=error,ePermissionsReadable=1,ePermissionsWritable=2,LLDB_INVALID_ADDRESS=-1)
            files=bridge.RemoteFiles(process,evaluate,lldb);files.function=lambda name,signature:'(('+signature+')open)' if name=='open' else name;files.upload(local,'/var/mobile/cache/LookinServer');files.close()
            self.assertEqual(bytes(written),b'abcdef')
            self.assertTrue(any('int, ...' in e and 'open)' in e for e in expressions))
            self.assertEqual(expressions[-1],'chmod("/var/mobile/cache/LookinServer", 448)')

    def test_existing_remote_directory_is_checked_and_closed(self):
        expressions=[]
        def evaluate(expression):
            expressions.append(expression)
            return Value(17 if 'mkdir(' in expression else 4096 if 'opendir(' in expression else 0)
        files=object.__new__(bridge.RemoteFiles);files.evaluate=evaluate;files.function=lambda name,signature:name
        files.mkdir('/var/cache')
        self.assertEqual(expressions.count('closedir((void *)0x1000)'),1)

    def test_remote_directory_failure_is_not_ignored(self):
        files=object.__new__(bridge.RemoteFiles);files.function=lambda name,signature:name
        files.evaluate=lambda e:Value(17 if 'mkdir(' in e else 0)
        with self.assertRaisesRegex(RuntimeError,'Unable to create or access'):files.mkdir('/var/cache')
        with self.assertRaisesRegex(RuntimeError,'absolute path'):files.mkdir('../cache')

    def test_remote_directory_recurses_only_into_missing_parent(self):
        expressions=[];results=iter([2,2,17,4096,0,0,0])
        def evaluate(expression):
            expressions.append(expression);return Value(next(results))
        files=object.__new__(bridge.RemoteFiles);files.evaluate=evaluate;files.function=lambda name,signature:name
        files.mkdir('/var/mobile/Library/Caches/LookinMCP/session')
        self.assertEqual(len(expressions),7)
        self.assertFalse(any('"/var"' in e or '"/var/mobile"' in e for e in expressions))
        self.assertTrue(any('opendir("/var/mobile/Library/Caches")' in e for e in expressions))

    def test_disabled_integration_never_inspects_target(self):
        with tempfile.TemporaryDirectory() as temporary,patch.object(bridge,'ROOT',Path(temporary)),patch.dict('sys.modules',{'lldb':SimpleNamespace()}):
            bridge.load(None,'',None,{})
            self.assertFalse((Path(temporary)/'last-session.json').exists())

if __name__=='__main__':unittest.main()
