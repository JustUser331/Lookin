#!/usr/bin/env python3
"""Prepare the pinned server and CocoaPods workspaces for this fork."""
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def run(args, cwd=ROOT):
    subprocess.run([str(arg) for arg in args], cwd=cwd, check=True,
                   env=os.environ | {'COCOAPODS_DISABLE_STATS': 'true'})


def setup():
    dependency = json.loads((ROOT / 'Dependencies/LookinServer.json').read_text())
    server = ROOT / 'build/Dependencies/LookinServer'
    if not server.exists():
        server.parent.mkdir(parents=True, exist_ok=True)
        run(['git', 'clone', dependency['repository'], server])
    if (server / '.git/index').exists() and subprocess.check_output(['git', '-C', str(server), 'status', '--porcelain']).strip():
        raise RuntimeError('The cached server has local changes. Preserve them before running setup.')
    available = subprocess.run(['git', '-C', str(server), 'cat-file', '-e', dependency['revision'] + '^{commit}'],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if available.returncode:
        run(['git', '-C', server, 'fetch', 'origin', dependency['revision']])
    run(['git', '-C', server, 'checkout', '--detach', dependency['revision']])
    builder = ROOT / 'build/ServerBuilder'
    builder.mkdir(parents=True, exist_ok=True)
    project = builder / 'ServerBuilder.xcodeproj'
    if not project.exists():
        shutil.copytree(ROOT / 'BuildSupport/ServerBuilder.xcodeproj', project)
    shutil.copy2(ROOT / 'BuildSupport/Podfile', builder / 'Podfile')
    lock = ROOT / 'BuildSupport/Podfile.lock'
    if lock.exists():
        shutil.copy2(lock, builder / 'Podfile.lock')
    run(['pod', 'install', '--no-repo-update'], builder)
    run(['pod', 'install', '--no-repo-update'])
    actual = subprocess.check_output(['git', '-C', str(server), 'rev-parse', 'HEAD'], text=True).strip()
    if actual != dependency['revision']:
        raise RuntimeError('Server checkout does not match the pinned revision.')
    print('Ready: Lookin.xcworkspace; server revision ' + actual)


if __name__ == '__main__':
    setup()
