#!/usr/bin/env python3
"""Run the portable client and pinned-server regression suites after building."""
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
frameworks = ROOT / 'build/ClientDerivedData/Build/Products/Release/LookinShared'
server = ROOT / 'build/Dependencies/LookinServer'
subprocess.run(['swift', 'test', '--package-path', str(ROOT / 'ResourceCore')], check=True)
subprocess.run(['swift', 'test', '--package-path', str(ROOT / 'AgentBridge')], check=True)
client_suites = ['connection_regressions.py', 'discovery_regressions.py', 'coordinator_regressions.py',
                 'preview_geometry_regressions.py', 'preview_image_cache_regressions.py',
                 'resource_pipeline_regressions.py', 'simulator_autoconnect_regressions.py',
                 'device_connection_regressions.py', 'device_lldb_regressions.py',
                 'xcode_integration_regressions.py', 'Performance/test_compare_captures.py']
for name in client_suites:
    print('TEST client/' + name, flush=True)
    subprocess.run([sys.executable, '-B', str(ROOT / 'Tests' / name)], check=True)
for name in ['bitmap_budget_regressions.py', 'constraint_index_regressions.py',
             'foreground_request_regressions.py', 'startup_regressions.py', 'socket_connect_regressions.py', 'png_encoding_cache_regressions.py',
             'resource_codec_regressions.py', 'simulator_app_identity_regressions.py']:
    print('TEST server/' + name, flush=True)
    args = ['--framework-dir', str(frameworks)] if name in ['resource_codec_regressions.py', 'simulator_app_identity_regressions.py'] else []
    subprocess.run([sys.executable, '-B', str(server / 'Tests' / name), *args], check=True)
print('All client and server regression suites passed.')
