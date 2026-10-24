#!/usr/bin/env python3
"""Give content-changed source files fresh timestamps for an incremental CMake cache."""
import hashlib
import json
import os
from pathlib import Path
import stat
import time


def normalize(source, state_file):
    previous = json.loads(state_file.read_text()) if state_file.exists() else {}
    current = {}
    now = int(time.time() * 1000000000)
    for path in sorted(source.rglob('*')):
        if not path.is_file() or path.is_symlink():
            continue
        key = str(path.relative_to(source))
        identity = [hashlib.sha256(path.read_bytes()).hexdigest(), stat.S_IMODE(path.stat().st_mode)]
        old = previous.get(key)
        timestamp = old['timestamp'] if old and old['identity'] == identity else now
        os.utime(str(path), ns=(timestamp, timestamp))
        current[key] = {'identity': identity, 'timestamp': timestamp}
    state_file.write_text(json.dumps(current, sort_keys=True)+'\n')


if __name__ == '__main__':
    normalize(Path('/source'), Path('/work/source-stamps.json'))
