"""La bibliothèque privée survit au remplacement par une APK sans données initiales."""
import json
from pathlib import Path
import tempfile
import unittest

from mobile_engine import Engine


class DistributionEngineTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.seed = self.root / 'seed'
        self.seed.mkdir()
        audit = self.seed / 'recherche-catalogues/audit-complet/resultats-revus.json'
        audit.parent.mkdir(parents=True)
        audit.write_text('{"date":"2026-11-26","sources":{}}', encoding='utf-8')
        self.library = self.seed / 'mangatime-20261119-134639-04c64935.json'
        self.library.write_text('[]', encoding='utf-8')
        self.runtime = self.root / 'runtime'

    def test_fresh_public_install_contains_no_personal_data(self):
        engine = Engine(self.runtime, self.seed)
        self.assertEqual(engine.request('history'), [])
        self.assertEqual(engine.request('mangatime/library'), [])

    def test_bootstrap_keeps_library_and_history_across_public_update(self):
        rows = [{'titre': 'Lecture personnelle de test', 'statut': 'À lire',
                 'note': None, 'note_privee': 'Une annotation', 'type': None, 'listes': []}]
        self.library.write_text(json.dumps(rows), encoding='utf-8')
        original = Engine(self.runtime, self.seed)
        original.store.save_run({'id': 'old-run', 'status': 'done', 'scope': 'discovery', 'prompt': 'Une ancienne demande',
                                 'result': {'status': 'no_match'}})
        self.library.write_text('[]', encoding='utf-8')
        updated = Engine(self.runtime, self.seed)
        self.assertEqual(updated.store.library, rows)
        self.assertEqual(updated.request('history')[0]['id'], 'old-run')

    def test_imported_export_survives_restart_including_explicit_empty_library(self):
        engine = Engine(self.runtime, self.seed)
        rows = [{'titre': 'Une nouvelle lecture', 'statut': 'En pause'}]
        self.assertEqual(engine.request('mangatime/library', {'library': rows}), rows)
        restarted = Engine(self.runtime, self.seed)
        self.assertEqual(restarted.store.library, rows)
        restarted.request('mangatime/library', {'library': []})
        self.assertEqual(Engine(self.runtime, self.seed).store.library, [])

    def test_bad_import_keeps_last_library(self):
        engine = Engine(self.runtime, self.seed)
        with self.assertRaises(ValueError):
            engine.request('mangatime/library', {'library': [{'titre': None}]})
        self.assertEqual(Engine(self.runtime, self.seed).store.library, [])
