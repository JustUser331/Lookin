# Этот файл добавляется к модулю ios-deploy; lldb/listener уже инициализированы.
def lookin_connect(debugger, command, result, internal_dict):
    import json
    from pathlib import Path
    config = LOOKIN_CONFIG
    target = debugger.GetSelectedTarget()
    process = None
    breakpoint = None
    report = {'success': False, 'mode': config['mode']}
    try:
        target.GetModuleAtIndex(0).SetPlatformFileSpec(lldb.SBFileSpec(internal_dict['fruitstrap_device_app']))
        error = lldb.SBError()
        if config['mode'] == 'attach':
            attach = lldb.SBAttachInfo(config['pid'])
            process = target.Attach(attach, error)
        else:
            breakpoint = target.BreakpointCreateByName('UIApplicationMain')
            launch = lldb.SBLaunchInfo([])
            launch.SetListener(listener)
            process = target.Launch(launch, error)
        if error.Fail():
            raise RuntimeError(str(error))
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            if process.GetState() == lldb.eStateStopped and process.GetNumThreads():
                break
            event = lldb.SBEvent()
            if listener.WaitForEvent(1, event):
                state = process.GetStateFromEvent(event)
                if state == lldb.eStateStopped and process.GetNumThreads():
                    break
                if state in (lldb.eStateExited, lldb.eStateCrashed, lldb.eStateDetached):
                    raise RuntimeError('The application ended before loading LookinServer.')
        else:
            raise RuntimeError('Debugger stop timed out. Unlock the device and stop the existing Xcode debugger before retrying.')
        thread = process.GetThreadAtIndex(0)
        process.SetSelectedThread(thread)
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

        bundle = json.dumps(config['bundleID'])
        if not evaluate('(BOOL)[(id)[(id)[(id)objc_getClass("NSBundle") mainBundle] bundleIdentifier] isEqualToString:@' + bundle + ']').GetValueAsUnsigned():
            raise RuntimeError('The debugger attached to a different application. Nothing was injected.')
        if config['mode'] == 'attach':
            state = evaluate('(long)[(id)[(id)objc_getClass("UIApplication") sharedApplication] applicationState]').GetValueAsSigned()
            if state != 0:
                raise RuntimeError('Open this app on the device before attaching.')
        report['pid'] = process.GetProcessID()
        report['wasLoaded'] = bool(evaluate('(void *)objc_getClass("Lookin")').GetValueAsUnsigned())
        if report['wasLoaded']:
            token_value = evaluate('(char *)getenv("LOOKIN_DEVICE_SESSION")')
            previous = json.loads(token_value.GetSummary() or '""')
            import re
            if not re.fullmatch(r'[a-f0-9]{32}', previous):
                raise RuntimeError('Another LookinServer is already loaded. Select the app in Lookin, or quit it and use Launch.')
            report.update(success=True, session=previous)
            return
        token = json.dumps(config['session'])
        evaluate('(int)setenv("LOOKIN_DEVICE_SESSION", ' + token + ', 1)')
        path = json.dumps(config['remotePath'])
        handle = evaluate('(void *)dlopen((const char *)[(id)[(id)NSHomeDirectory() stringByAppendingPathComponent:@' + path + '] UTF8String], 2)')
        if handle.GetValueAsUnsigned() == 0:
            detail = evaluate('(char *)dlerror()')
            raise RuntimeError('LookinServer could not be loaded: ' + (detail.GetSummary() or str(detail)))
        if not evaluate('(void *)objc_getClass("LKS_ConnectionManager")').GetValueAsUnsigned():
            raise RuntimeError('The loaded library is not LookinServer.')
        # При attach событие активации уже прошло; активируем только сервер, без рассылки UIKit-уведомлений.
        if config['mode'] == 'attach':
            evaluate('((void)[(id)[(id)objc_getClass("LKS_ConnectionManager") sharedInstance] _handleApplicationDidBecomeActive], 1)')
        report['serverPath'] = [str(target.GetModuleAtIndex(i).GetPlatformFileSpec()) for i in range(target.GetNumModules()) if 'LookinServer' in str(target.GetModuleAtIndex(i).GetFileSpec())]
        report['success'] = True
    except Exception as error:
        report['error'] = str(error)
    finally:
        if breakpoint:
            target.BreakpointDelete(breakpoint.GetID())
        if process and process.IsValid() and process.GetState() not in (lldb.eStateExited, lldb.eStateDetached):
            detached = process.Detach()
            report['detached'] = detached.Success()
            if detached.Fail():
                report['success'] = False
                report['error'] = 'Unable to detach the debugger: ' + str(detached)
        Path(config['report']).write_text(json.dumps(report, indent=2))
        print('LOOKIN_DEVICE_RESULT ' + json.dumps(report), flush=True)
