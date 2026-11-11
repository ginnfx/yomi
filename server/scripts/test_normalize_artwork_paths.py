import importlib.util
from pathlib import Path
import sqlite3
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('normalizer', Path(__file__).with_name('normalize_artwork_paths.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class NormalizeTest(unittest.TestCase):
    def test_rebases_only_literal_music_roots_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as work:
            path = Path(work) / 'incoming.db'
            with sqlite3.connect(path) as db:
                db.execute('create table library(path text)')
                db.execute('insert into library values (?)', ('/cloud/music_root',))
                db.execute('create table item_artwork(source_path text, hash text)')
                db.executemany('insert into item_artwork values (?, ?)', [
                    ('/cloud/music_root/admin/song.m4a','revision-a'),
                    ('/android/music/admin/song.m4a','revision-b'),
                    ('/cloud/musicXroot/admin/unrelated.m4a','revision-c'),
                    ('https://example.com/art.jpg','revision-d'),
                ])
            target = (Path(work) / 'local-music').resolve()
            self.assertEqual(module.normalize(path,target,['/android/music']),2)
            self.assertEqual(module.normalize(path,target,['/android/music']),0)
            with sqlite3.connect(path) as db:
                rows=db.execute('select * from item_artwork').fetchall()
            self.assertEqual(rows,[(str(target)+'/admin/song.m4a','revision-a'),(str(target)+'/admin/song.m4a','revision-b'),('/cloud/musicXroot/admin/unrelated.m4a','revision-c'),('https://example.com/art.jpg','revision-d')])

    def test_multiple_libraries_are_refused_without_mutation(self):
        with tempfile.TemporaryDirectory() as work:
            path=Path(work)/'incoming.db'
            with sqlite3.connect(path) as db:
                db.execute('create table library(path text)')
                db.executemany('insert into library values (?)',[('/a',),('/b',)])
            with self.assertRaises(ValueError):module.normalize(path,Path(work)/'music')

if __name__=='__main__':unittest.main()
