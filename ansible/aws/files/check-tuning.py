#!/usr/bin/env python3
import pathlib
import sys

for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    if not line.strip():
        continue
    key, desired = line.split('=', 1)
    path = pathlib.Path('/proc/sys') / key.strip().replace('.', '/')
    if not path.exists():
        sys.exit(2)
    if path.read_text().split() != desired.split():
        sys.exit(1)
sys.exit(0)
