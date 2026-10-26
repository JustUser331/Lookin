#!/usr/bin/env python3
"""Exercise the new six-tool interface against a running app, without modifying it."""
import argparse
import base64
import json
from pathlib import Path
import struct
import urllib.error
import urllib.request

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--bundle', required=True)
parser.add_argument('--endpoint', default='http://127.0.0.1:47199/mcp')
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
checks = {}
sequence = 0
headers = {'Accept': 'application/json, text/event-stream', 'Content-Type': 'application/json'}

def http(method='POST', body=None, extra=None, endpoint=None):
    request = urllib.request.Request(endpoint or args.endpoint, data=body, headers=headers | (extra or {}), method=method)
    try:
        with urllib.request.urlopen(request, timeout=42) as response: return response.status, response.read()
    except urllib.error.HTTPError as response: return response.code, response.read()

def rpc(method, params=None):
    global sequence
    sequence += 1
    status, body = http(body=json.dumps({'jsonrpc': '2.0', 'id': sequence, 'method': method, 'params': params or {}}).encode())
    assert status == 200, (status, body[:500])
    result = json.loads(body)
    assert result.get('id') == sequence, result
    return result

def tool(name, arguments=None, error=None):
    result = rpc('tools/call', {'name': name, 'arguments': arguments or {}})
    assert 'result' in result, result
    result = result['result']
    data = result.get('structuredContent') or json.loads(result['content'][0]['text'])
    if error:
        assert result.get('isError') and data.get('error', {}).get('code') == error, data
    else: assert not result.get('isError'), data
    return data, result

def passed(name):
    checks[name] = True
    print('PASS', name, flush=True)

initial = rpc('initialize', {'protocolVersion': '2025-11-25', 'capabilities': {}, 'clientInfo': {'name': 'lookin-live-test', 'version': '1'}})
assert initial['result']['serverInfo']['name'] == 'lookin-agent'
passed('initialize')
definitions = rpc('tools/list')['result']['tools']
assert {t['name'] for t in definitions} == {'list_apps', 'connect_app', 'get_snapshot', 'find_nodes', 'get_node', 'get_image'}
passed('six tool schemas')
apps, _ = tool('list_apps')
app = next((app for app in apps['apps'] if app['bundleId'] == args.bundle), None)
assert app, apps
connected, _ = tool('connect_app', {'appRef': app['appRef']})
snapshot = connected['snapshotId']
passed('discover and connect exact app')
first, _ = tool('get_snapshot', {'snapshotId': snapshot, 'depth': 64, 'limit': 2})
assert 0 < len(first['nodes']) <= 2 and first['totalNodes'] > 2
root = first['nodes'][0]['ref']
second, _ = tool('get_snapshot', {'snapshotId': snapshot, 'depth': 64, 'limit': 2, 'offset': first['nextOffset']})
assert not ({n['ref'] for n in first['nodes']} & {n['ref'] for n in second['nodes']})
passed('bounded snapshot and pagination')
node, _ = tool('get_node', {'ref': root})
assert node['attributes'] and node['snapshotId'] == snapshot
passed('on-demand attributes')
image, content = tool('get_image', {'ref': root})
png = base64.b64decode(next(c['data'] for c in content['content'] if c['type'] == 'image'))
assert png[:8] == b'\x89PNG\r\n\x1a\n'
width, height = struct.unpack('>II', png[16:24]); assert width > 0 and height > 0
(args.output / 'root.png').write_bytes(png)
passed('native PNG')
found, _ = tool('find_nodes', {'query': 'UILabel', 'field': 'class', 'limit': 10})
assert found['matched'] > 0 and len(found['nodes']) <= 10
passed('class search')
_, leaf = tool('get_image', {'ref': found['nodes'][0]['ref'], 'includeChildren': False})
assert base64.b64decode(next(c['data'] for c in leaf['content'] if c['type'] == 'image'))[:8] == b'\x89PNG\r\n\x1a\n'
passed('isolated leaf PNG')
for name, arguments in [('get_snapshot', {'limit': -1}), ('get_snapshot', {'limit': True}),
                        ('get_snapshot', {'unknown': 'field'}), ('find_nodes', {'query': 42})]:
    tool(name, arguments, error='invalid_arguments')
passed('argument type and bound validation')
tool('get_node', {'ref': 'old:n0'}, error='stale_ref')
refreshed, _ = tool('get_snapshot', {'refresh': True, 'limit': 1})
assert refreshed['snapshotId'] != snapshot
tool('get_node', {'ref': root}, error='stale_ref')
tool('get_snapshot', {'snapshotId': snapshot, 'offset': 1}, error='stale_snapshot')
passed('refresh invalidates refs and cursors')
assert http(method='GET')[0] == 405
assert http(body=b'{}', endpoint=args.endpoint + '/other')[0] == 404
assert http(body=b'{}', extra={'Host': 'attacker.example'})[0] == 403
assert http(body=b'{}', extra={'Origin': 'https://attacker.example'})[0] == 403
assert http(body=b' ' * (1024 * 1024 + 1))[0] == 413
passed('HTTP endpoint, origin, host and body limits')
unknown = rpc('tools/call', {'name': 'execute_arbitrary_code', 'arguments': {}})
assert unknown['error']['code'] == -32602
passed('unknown tool rejected')
report = {'passed': True, 'bundle': args.bundle, 'app': app, 'nodes': first['totalNodes'],
          'png': {'bytes': len(png), 'width': width, 'height': height}, 'checks': checks}
(args.output / 'report.json').write_text(json.dumps(report, indent=2))
print(json.dumps({'passed': True, 'nodes': report['nodes'], 'checks': len(checks)}))
