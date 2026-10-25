#!/usr/bin/env python3
"""Materialize the selected script release for Docker's named build context."""
import argparse
import io
import json
from pathlib import Path, PurePosixPath
import re
import tarfile
import tempfile
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[1]


def materialize(context, destination):
    if destination.is_dir():
        return destination
    destination.parent.mkdir(parents=True, exist_ok=True)
    with urlopen(context, timeout=60) as response:
        payload = response.read()
    # Publish bundles contain regular allowlisted files, never Git history or links.
    with tempfile.TemporaryDirectory(dir=destination.parent, prefix='.download-') as temporary:
        staged = Path(temporary) / 'files'
        staged.mkdir()
        with tarfile.open(fileobj=io.BytesIO(payload), mode='r:gz') as archive:
            for member in archive.getmembers():
                path = PurePosixPath(member.name)
                if (not member.isfile() or path.is_absolute() or
                        any(part.startswith('.') for part in path.parts)):
                    raise ValueError('Invalid script bundle member: ' + member.name)
                target = staged / member.name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(archive.extractfile(member).read())
                target.chmod(0o755 if target.suffix == '.sh' else 0o644)
        staged.rename(destination)
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--url-only', action='store_true', help='Print selected release without downloading')
    args = parser.parse_args()
    context = json.loads((ROOT / 'tool-scripts.json').read_text())['context']
    match = re.fullmatch(r'https://[^/\s]+/revisions/([0-9a-f]{40})/tool-scripts\.tar\.gz', context)
    if not match:
        raise SystemExit('Select an immutable tool-scripts revision in tool-scripts.json')
    if args.url_only:
        print(context)
    else:
        print(materialize(context, ROOT / '.work/tool-scripts' / match[1]))


if __name__ == '__main__':
    main()
