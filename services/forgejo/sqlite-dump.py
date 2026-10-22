#!/usr/bin/env python3
"""Crash-consistent sqlite backup via sqlite's online backup API (WAL-safe).
Usage: sqlite-dump.py <src.db> <dst.db>
Writes to dst.tmp then atomic-replaces, so a failure never corrupts the last good copy.
"""
import sqlite3, sys, os

src, dst = sys.argv[1], sys.argv[2]
os.makedirs(os.path.dirname(dst) or ".", exist_ok=True)
tmp = dst + ".tmp"
try:
    so = sqlite3.connect(src, timeout=30)
    de = sqlite3.connect(tmp)
    so.backup(de)
    de.close()
    so.close()
    os.replace(tmp, dst)
    print("OK", src, "->", dst)
except Exception as e:  # noqa: BLE001
    print("FAIL", src, repr(e))
    try:
        os.unlink(tmp)
    except OSError:
        pass
    sys.exit(1)