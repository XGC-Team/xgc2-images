#!/usr/bin/env python3
"""Require first-party modules in Go's resolved graph to use local source providers."""
import json
from pathlib import Path
import subprocess


def verify(modules, source):
    for module in modules:
        if not module['Path'].lower().startswith('github.com/xgc-team/'):
            continue
        if not module.get('Main'):
            raise ValueError('First-party Go module has no local workspace provider: '+module['Path'])
        Path(module['Dir']).resolve().relative_to(source.resolve())


if __name__ == '__main__':
    raw = subprocess.check_output(['go','list','-m','-json','all'], universal_newlines=True)
    decoder = json.JSONDecoder()
    modules = []
    while raw.strip():
        item, end = decoder.raw_decode(raw.lstrip())
        raw = raw.lstrip()[end:]
        modules.append(item)
    verify(modules, Path('/source'))
