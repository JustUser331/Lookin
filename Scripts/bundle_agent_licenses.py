"""Include notices from the resolved official SDK and its dependencies."""
import argparse
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--checkouts', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
copied = []
for package in sorted(args.checkouts.iterdir()):
    if not package.is_dir(): continue
    for pattern in ['LICENSE*', 'COPYING*', 'NOTICE*']:
        for source in sorted(package.glob(pattern)):
            if not source.is_file(): continue
            name = package.name + '-' + source.name
            temporary = args.output / (name + '.tmp')
            temporary.write_bytes(source.read_bytes())
            temporary.replace(args.output / name)
            copied.append(name)
if not any(name.startswith('swift-sdk-') for name in copied):
    raise RuntimeError('The resolved MCP SDK license was not found.')
(args.output / 'INDEX.txt').write_text('Third-party notices for Lookin Agent MCP\n' + '\n'.join(copied) + '\n')
