"""Validate device input/signing boundaries without touching a physical device."""
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

source = Path(__file__).resolve().parents[1] / 'DeviceSupport/device_connect.py'
spec = importlib.util.spec_from_file_location('device_connect', source)
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


class DeviceConnectionTests(unittest.TestCase):
    def test_usb_catalog_excludes_wifi_and_reports_unsupported_os(self):
        def event(identifier, version, interface='USB'):
            return {'Event': 'DeviceDetected', 'Interface': interface, 'Device': {'DeviceIdentifier': identifier, 'ProductVersion': version, 'DeviceClass': 'iPhone'}}
        output = ''.join(json.dumps(e) for e in [event('x','16.2'),event('new','26.5'),event('wifi','16.2','WIFI')])
        with patch.object(helper, 'run', return_value=(0,output,'')):
            self.assertEqual([(d['id'],d['supported']) for d in helper.devices()], [('x',True),('new',False)])

    def make_app(self, root, platforms):
        app = Path(root) / 'Fixture.app'
        app.mkdir()
        (app / 'Fixture').write_bytes(b'fixture')
        (app / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'local.fixture','CFBundleExecutable':'Fixture','CFBundleSupportedPlatforms':platforms}))
        return app

    def test_simulator_is_rejected_before_signing(self):
        with tempfile.TemporaryDirectory() as root:
            app = self.make_app(root,['iPhoneSimulator'])
            with patch.object(helper,'run') as runner, self.assertRaisesRegex(RuntimeError,'iPhoneOS'):
                helper.inspect_app(app)
            runner.assert_not_called()

    def test_release_entitlements_are_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            app = self.make_app(root,['iPhoneOS'])
            xml = plistlib.dumps({'get-task-allow':False}).decode()
            with patch.object(helper,'run',side_effect=[(0,'',''),(0,xml,'')]), self.assertRaisesRegex(RuntimeError,'not debuggable'):
                helper.inspect_app(app)

    def test_debug_entitlements_are_accepted(self):
        with tempfile.TemporaryDirectory() as root:
            app = self.make_app(root,['iPhoneOS'])
            xml = plistlib.dumps({'get-task-allow':True}).decode()
            with patch.object(helper,'run',side_effect=[(0,'',''),(0,xml,'')]):
                self.assertEqual(helper.inspect_app(app)[1],'local.fixture')

    def test_unknown_certificate_is_rejected(self):
        def run(args,**kwargs):
            if args[0]=='codesign': Path(args[2].split('=',1)[1]+'0').write_bytes(b'certificate')
            return 0,'  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Apple Development"\n',''
        with patch.object(helper,'run',side_effect=run), self.assertRaisesRegex(RuntimeError,'private key'):
            helper.signing_identity(Path('/tmp/Fake.app'))

    def test_invalid_device_cannot_reach_tools(self):
        class Args:device='bad;command';app='/tmp/Fake.app';mode='launch'
        with patch.object(helper,'run') as runner, self.assertRaisesRegex(RuntimeError,'identifier'):
            helper.connect(Args())
        runner.assert_not_called()

    def test_debugger_path_quotes_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            app=Path(root)/'bad".app';app.mkdir()
            with self.assertRaisesRegex(RuntimeError,'quotes'):helper.inspect_app(app)


if __name__ == '__main__': unittest.main()
