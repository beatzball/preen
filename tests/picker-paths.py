#!/usr/bin/env python3
"""Read actual review records and emit their NUL-framed original path field."""
import sys

for record in sys.stdin.buffer.read().split(b"\0"):
    if not record:
        continue
    fields = record.split(b"\x1f", 2)
    if len(fields) != 3:
        sys.exit("review record has no raw path field")
    sys.stdout.buffer.write(fields[2] + b"\0")
