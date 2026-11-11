#!/usr/bin/env python3
"""Rebase Navidrome artwork references after copying a single-library database.

Run on the incoming database before exposing a replica. Existing media bytes and
artwork hashes are unchanged. Explicit extra roots repair earlier host migrations.
"""
import argparse
from pathlib import Path
import sqlite3


def normalize(database, music_dir, extra_roots=()):
    target = str(Path(music_dir).resolve())
    with sqlite3.connect(database, timeout=30) as db:
        libraries = db.execute('select path from library').fetchall()
        if len(libraries) != 1:
            raise ValueError('Expected one library; multiple libraries need explicit mapping')
        roots = {path.rstrip('/') for path, in libraries} | {
            str(root).rstrip('/') for root in extra_roots
        }
        changed = 0
        for root in sorted(roots - {target}):
            if not root.startswith('/') or root == '':
                raise ValueError('Source roots must be absolute')
            # Prefix matching is literal: underscores/percent in paths are not wildcards.
            changed += db.execute(
                'update item_artwork set source_path = ? || substr(source_path, ?) '
                'where substr(source_path, 1, ?) = ?',
                (target, len(root) + 1, len(root) + 1, root + '/'),
            ).rowcount
        if db.execute('pragma quick_check').fetchone()[0] != 'ok':
            raise ValueError('Database integrity check failed')
        return changed


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('database')
    parser.add_argument('music_dir')
    parser.add_argument('--source-root', action='append', default=[])
    args = parser.parse_args()
    print('Normalized artwork paths:', normalize(args.database, args.music_dir, args.source_root))
