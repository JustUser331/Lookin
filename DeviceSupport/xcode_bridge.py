"""Load Lookin through the current Xcode debugger without attaching/detaching it."""
from pathlib import Path
import hashlib
import importlib.util
import json
import os
import plistlib
import re
import shlex
import shutil
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parent


def app_for_target(target):
    executable = Path(str(target.GetExecutable()))
    for parent in executable.parents:
        if parent.suffix == '.app' and (parent / 'Info.plist').is_file():
            return parent
    raise RuntimeError('Xcode did not provide the local application bundle.')


def tools_module():
    spec = importlib.util.spec_from_file_location('_lookin_device_tools', ROOT / 'device_connect.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def signed_payload(app, tools):
    identity = tools.signing_identity(app)
    source = ROOT / 'LookinServer.framework'
    digest = hashlib.sha256((source / 'LookinServer').read_bytes() + (source / 'Info.plist').read_bytes() + identity.encode()).hexdigest()
    cache = ROOT / 'SignedCache' / digest
    framework = cache / 'LookinServer.framework'
    if framework.exists():
        tools.run(['codesign', '--verify', '--strict', framework])
        return framework
    cache.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix='sign-', dir=cache.parent))
    try:
        payload = temporary / 'LookinServer.framework'
        payload.mkdir()
        # Заголовки и Swift-модули нужны компилятору, но не загружаемому runtime.
        for name in ['LookinServer', 'Info.plist']:
            shutil.copy2(source / name, payload / name)
        tools.run(['codesign', '--force', '--sign', identity, '--timestamp=none', payload])
        tools.run(['codesign', '--verify', '--strict', payload])
        try:
            temporary.rename(cache)
        except FileExistsError:
            pass
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)
    return framework


def function_pointer(target, lldb, name, signature):
    # Берём загруженный символ, а не объявления из debug info приложения.
    addresses = set()
    for context in target.FindSymbols(name):
        address = context.GetSymbol().GetStartAddress().GetLoadAddress(target)
        if address not in (0, lldb.LLDB_INVALID_ADDRESS):
            addresses.add(address)
    if len(addresses) != 1:
        raise RuntimeError('Unable to resolve an unambiguous loaded system function: ' + name)
    return '((%s)0x%x)' % (signature, addresses.pop())


class RemoteFiles:
    def __init__(self, process, evaluate, lldb):
        self.process, self.evaluate, self.lldb = process, evaluate, lldb
        self.functions = {}
        self.capacity = 64 * 1024
        error = lldb.SBError()
        self.buffer = process.AllocateMemory(self.capacity, lldb.ePermissionsReadable | lldb.ePermissionsWritable, error)
        if error.Fail() or not self.buffer or self.buffer == lldb.LLDB_INVALID_ADDRESS:
            raise RuntimeError('Unable to allocate the debugger transfer buffer: ' + str(error))

    def function(self, name, signature):
        if name not in self.functions:
            self.functions[name] = function_pointer(self.process.GetTarget(), self.lldb, name, signature)
        return self.functions[name]

    def mkdir(self, path):
        # POSIX-вызовы не зависят от разрешения Objective-C методов в LLDB.
        directory = Path(path)
        if not directory.is_absolute() or '..' in directory.parts:
            raise RuntimeError('The remote cache directory must be an absolute path.')
        quoted = json.dumps(str(directory))
        # errno читается в том же выражении; служебные вызовы LLDB не меняют его.
        mkdir = self.function('mkdir', 'int (*)(const char *, unsigned short)')
        errno = self.function('__error', 'int *(*)(void)')
        expression = '({ int r = ' + mkdir + '(' + quoted + ', 0700); r == 0 ? 0 : *' + errno + '(); })'
        error = self.evaluate(expression).GetValueAsSigned()
        if error == 2 and directory.parent != directory:  # ENOENT
            # Идём от целевой папки: sandbox не разрешает перечислять /var.
            self.mkdir(str(directory.parent))
            error = self.evaluate(expression).GetValueAsSigned()
        if error == 0:
            return
        if error == 17:  # EEXIST
            handle = self.evaluate(self.function('opendir', 'void *(*)(const char *)') + '(' + quoted + ')').GetValueAsUnsigned()
            if handle:
                self.evaluate(self.function('closedir', 'int (*)(void *)') + '((void *)0x%x)' % handle)
                return
        raise RuntimeError('Unable to create or access the Lookin cache directory on the device (errno %d).' % error)

    def upload(self, local, remote):
        self.mkdir(str(Path(remote).parent))
        descriptor = self.evaluate(self.function('open', 'int (*)(const char *, int, ...)') + '(' + json.dumps(remote) + ', 0x601, 0700)').GetValueAsSigned()
        if descriptor < 0:
            raise RuntimeError('Unable to create the server file on the device.')
        try:
            with local.open('rb') as stream:
                while True:
                    chunk = stream.read(self.capacity)
                    if not chunk:
                        break
                    error = self.lldb.SBError()
                    count = self.process.WriteMemory(self.buffer, chunk, error)
                    if error.Fail() or count != len(chunk):
                        raise RuntimeError('Debugger transfer failed: ' + str(error))
                    offset = 0
                    while offset < len(chunk):
                        written = self.evaluate(self.function('write', 'long (*)(int, const void *, unsigned long)') + '(%d, (void *)0x%x, %d)' % (descriptor, self.buffer + offset, len(chunk) - offset)).GetValueAsSigned()
                        if written <= 0:
                            raise RuntimeError('Writing the server file on the device failed.')
                        offset += written
        finally:
            self.evaluate(self.function('close', 'int (*)(int)') + '(%d)' % descriptor)
        # Явная variadic-сигнатура open и chmod исключают неверные права при разных LLDB type contexts.
        permissions = 0o700 if local.name == 'LookinServer' else 0o600
        if self.evaluate(self.function('chmod', 'int (*)(const char *, unsigned short)') + '(' + json.dumps(remote) + ', ' + str(permissions) + ')').GetValueAsSigned() != 0:
            raise RuntimeError('Unable to set readable permissions on the transferred server file.')

    def close(self):
        error = self.process.DeallocateMemory(self.buffer)
        if error.Fail():
            raise RuntimeError('Unable to release the debugger transfer buffer: ' + str(error))


def load(debugger, command, result, internal_dict):
    import lldb
    config_path = ROOT / 'config.json'
    report = {'success': False, 'debuggerPreserved': True}
    start = time.monotonic()
    remote_files = None
    try:
        arguments = shlex.split(command)
        if arguments:
            raise RuntimeError('lookin-xcode-load takes no arguments; the target comes from Xcode.')
        config = json.loads(config_path.read_text()) if config_path.exists() else {}
        if not config.get('enabled'):
            return
        target = debugger.GetSelectedTarget()
        if not target.IsValid():
            return
        platform = target.GetPlatform().GetName()
        if platform not in ('remote-ios', 'ios-simulator'):
            return
        process = target.GetProcess()
        if not process.IsValid() or process.GetState() != lldb.eStateStopped:
            raise RuntimeError('The automatic startup breakpoint must run while the process is stopped.')
        app = app_for_target(target)
        if platform == 'ios-simulator':
            bundle = plistlib.loads((app / 'Info.plist').read_bytes()).get('CFBundleIdentifier')
            if not isinstance(bundle, str) or not bundle:
                raise RuntimeError('The Simulator application has no bundle identifier.')
        else:
            tools = tools_module()
            app, bundle, _ = tools.inspect_app(app, require_debugger_safe_path=False)
        report.update(bundleID=bundle, localApp=str(app), pid=process.GetProcessID(), platform=platform)
        thread = process.GetSelectedThread()
        frame = thread.GetFrameAtIndex(0)
        options = lldb.SBExpressionOptions()
        options.SetLanguage(lldb.eLanguageTypeObjC_plus_plus)
        options.SetTimeoutInMicroSeconds(15000000)
        options.SetIgnoreBreakpoints(True)
        options.SetUnwindOnError(True)

        def evaluate(expression):
            report['lastExpression'] = expression
            value = frame.EvaluateExpression(expression, options)
            if value.GetError().Fail():
                raise RuntimeError(str(value.GetError()))
            return value

        # bundleIdentifier может падать при вызове из LLDB в реальном приложении.
        # Читаем тот же CFBundleIdentifier из Info.plist, сохраняя проверку цели.
        if not evaluate('(BOOL)[(id)[(id)[(id)objc_getClass("NSBundle") mainBundle] objectForInfoDictionaryKey:@"CFBundleIdentifier"] isEqualToString:@' + json.dumps(bundle) + ']').GetValueAsUnsigned():
            raise RuntimeError('The local build does not match the running application.')
        if evaluate('(void *)objc_getClass("Lookin")').GetValueAsUnsigned():
            token_value = evaluate('(char *)getenv("LOOKIN_DEVICE_SESSION")')
            token = json.loads(token_value.GetSummary() or '""')
            if isinstance(token, str) and re.fullmatch(r'[a-f0-9]{32}', token):
                report['session'] = token
            else:
                token = uuid.uuid4().hex
                evaluate('(int)setenv("LOOKIN_DEVICE_SESSION", ' + json.dumps(token) + ', 1)')
                report['session'] = token
            report.update(success=True, alreadyLoaded=True)
            return
        session = uuid.uuid4().hex
        if platform == 'ios-simulator':
            server = Path(config.get('simulatorServerPath', ROOT / 'Simulator/LookinServer.framework/LookinServer'))
            if not server.is_file():
                raise RuntimeError('The Simulator runtime is missing. Update Xcode Integration from Lookin.')
            evaluate('(int)setenv("LOOKIN_DEVICE_SESSION", ' + json.dumps(session) + ', 1)')
            # LLDB сам сопровождает загрузку образа и уведомления dyld, в том числе под Rosetta.
            error = lldb.SBError()
            image_token = process.LoadImage(lldb.SBFileSpec(str(server)), error)
            if error.Fail() or image_token == lldb.LLDB_INVALID_IMAGE_TOKEN:
                raise RuntimeError('Unable to load the Simulator server: ' + str(error))
            if not evaluate('(void *)objc_getClass("Lookin")').GetValueAsUnsigned():
                raise RuntimeError('The loaded server did not register its runtime classes.')
            report.update(success=True, session=session, serverPath=str(server), alreadyLoaded=False,
                          loader='lldb-load-image', imageToken=image_token)
            result.AppendMessage('Lookin: Simulator ready; Xcode debugging remains active.')
            return
        payload = signed_payload(app, tools)
        home_value = evaluate('(const char *)[(id)NSHomeDirectory() UTF8String]')
        error = lldb.SBError()
        home = process.ReadCStringFromMemory(home_value.GetValueAsUnsigned(), 4096, error)
        if error.Fail() or not home or not home.startswith('/private/var/') and not home.startswith('/var/'):
            raise RuntimeError('Unable to resolve the application data container.')
        remote_root = home + '/Library/Caches/LookinMCP/' + session + '/LookinServer.framework'
        remote_files = RemoteFiles(process, evaluate, lldb)
        for file in sorted(payload.rglob('*')):
            if file.is_file():
                remote_files.upload(file, remote_root + '/' + file.relative_to(payload).as_posix())
        remote_files.close()
        remote_files = None
        evaluate('(int)setenv("LOOKIN_DEVICE_SESSION", ' + json.dumps(session) + ', 1)')
        handle = evaluate('(void *)dlopen(' + json.dumps(remote_root + '/LookinServer') + ', 2)')
        if not handle.GetValueAsUnsigned():
            error = evaluate('(char *)dlerror()')
            raise RuntimeError('Unable to load the server: ' + (error.GetSummary() or str(error)))
        if not evaluate('(void *)objc_getClass("Lookin")').GetValueAsUnsigned():
            raise RuntimeError('The loaded server did not register its runtime classes.')
        report.update(success=True, session=session, serverPath=remote_root, alreadyLoaded=False)
        result.AppendMessage('Lookin: ready for connection; Xcode debugging remains active.')
    except Exception as error:
        report['error'] = str(error)
        result.AppendMessage('Lookin: ' + str(error) + ' The application can continue normally.')
    finally:
        if remote_files is not None:
            try:
                remote_files.close()
            except Exception:
                pass
        report['seconds'] = time.monotonic() - start
        if 'bundleID' in report or 'error' in report:
            try:
                temporary = ROOT / ('status-' + uuid.uuid4().hex + '.json')
                temporary.write_text(json.dumps(report, indent=2))
                os.replace(temporary, ROOT / 'last-session.json')
            except OSError:
                pass
        # Не вызываем Continue/Stop/Detach: жизненным циклом процесса управляет Xcode.


def __lldb_init_module(debugger, internal_dict):
    debugger.HandleCommand('command script add --overwrite -f ' + __name__ + '.load lookin-xcode-load')
