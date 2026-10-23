#!/usr/bin/env python3
"""Build the macOS client and both iOS runtimes without installing applications."""
import argparse
from pathlib import Path
import subprocess
from setup import setup, ROOT

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--skip-setup', action='store_true')
parser.add_argument('--configuration', choices=['Debug', 'Release'], default='Release')
parser.add_argument('--architectures', default='arm64 x86_64')
args = parser.parse_args()
if not args.skip_setup:
    setup()
subprocess.run(['xcodebuild', '-workspace', str(ROOT / 'Lookin.xcworkspace'), '-scheme', 'LookinClient',
                '-configuration', args.configuration, '-destination', 'generic/platform=macOS',
                '-derivedDataPath', str(ROOT / 'build/ClientDerivedData'),
                'ARCHS=' + args.architectures, 'ONLY_ACTIVE_ARCH=NO', 'CODE_SIGNING_ALLOWED=NO', 'build'], check=True)
print(ROOT / 'build/ClientDerivedData/Build/Products' / args.configuration / 'Lookin.app')
