#!/usr/bin/env python3
"""Verify discovery when two live Simulator apps reuse a listening port."""
import argparse
import json
from pathlib import Path
import subprocess
import time
import urllib.request

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--device', required=True)
parser.add_argument('--first', required=True)
parser.add_argument('--second', required=True)
parser.add_argument('--first-scheme', default='lookin-xcode-research')
parser.add_argument('--second-scheme', default='lookin-late-research')
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
sequence = 0

def tool(name, arguments=None):
    global sequence
    sequence += 1
    body = {'jsonrpc': '2.0', 'id': sequence, 'method': 'tools/call', 'params': {'name': name, 'arguments': arguments or {}}}
    request = urllib.request.Request('http://127.0.0.1:47199/mcp', data=json.dumps(body).encode(),
                                    headers={'Content-Type': 'application/json', 'Accept': 'application/json, text/event-stream'})
    result = json.load(urllib.request.urlopen(request, timeout=18))['result']
    data = result.get('structuredContent') or json.loads(result['content'][0]['text'])
    return data

captures = []
containers = {bundle: Path(subprocess.check_output(['xcrun', 'simctl', 'get_app_container', args.device, bundle, 'data'], text=True, timeout=10).strip()) for bundle in [args.first, args.second]}
for bundle in [args.first, args.second, args.first]:
    print('ACTIVATE', bundle, '- confirm Open in Simulator if prompted', flush=True)
    started = time.time()
    scheme = args.first_scheme if bundle == args.first else args.second_scheme
    subprocess.run(['xcrun', 'simctl', 'openurl', args.device, scheme + '://foreground'], check=True, timeout=10)
    deadline = time.monotonic() + 180
    active = None
    while time.monotonic() < deadline:
        active = json.loads((containers[bundle] / 'Documents/state.json').read_text())
        if active['applicationState'] == 0 and active['timestamp'] >= started: break
        time.sleep(0.1)
    assert active['applicationState'] == 0 and active['timestamp'] >= started, ('Simulator locked or app not active', active)
    pid = active['pid']
    deadline = time.monotonic() + 24
    found = None
    while time.monotonic() < deadline:
        apps = tool('list_apps')
        found = next((a for a in apps.get('apps', []) if a['bundleId'] == bundle), None)
        if found: break
        time.sleep(0.3)
    assert found, (bundle, apps)
    connected = tool('connect_app', {'appRef': found['appRef']})
    assert connected['app']['bundleId'] == bundle, connected
    snapshot = tool('get_snapshot', {'limit': 1})
    assert snapshot['app']['bundleId'] == bundle and snapshot['nodes'], snapshot
    image = tool('get_image', {'ref': snapshot['nodes'][0]['ref']})
    assert image.get('bytes', 0) > 0, image
    captures.append({'bundle': bundle, 'pid': pid, 'snapshotId': snapshot['snapshotId']})
    print('PASS foreground switch', bundle, pid, flush=True)
assert captures[0]['pid'] == captures[2]['pid'], captures
assert captures[0]['snapshotId'] != captures[2]['snapshotId'], captures
(args.output / 'report.json').write_text(json.dumps({'passed': True, 'captures': captures, 'desktopRestartUsed': False}, indent=2))
