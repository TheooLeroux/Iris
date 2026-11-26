import io
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

from release import inspect_apk, manifest


class DistributionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.apk = Path(self.temp.name) / 'test.apk'

    def build(self, library=None, database=False):
        nested = io.BytesIO()
        with zipfile.ZipFile(nested, 'w') as z:
            z.writestr('seed/mangatime-20261119-134639-04c64935.json', json.dumps(library or []))
            z.writestr('seed/recherche-catalogues/audit-complet/resultats-revus.json', '{"sources":{"mangadex":{}}}')
            if database:
                z.writestr('seed/recolecture.sqlite3', b'private')
        with zipfile.ZipFile(self.apk, 'w') as z:
            z.writestr('assets/chaquopy/app.imy', nested.getvalue())

    def test_public_apk_manifest(self):
        self.build()
        data = manifest(self.apk, '1.3.0', 5, 'TheooLeroux/Iris', 'Mise à jour')
        self.assertEqual(data['size'], self.apk.stat().st_size)
        self.assertEqual(data['build'], 5)
        self.assertEqual(len(data['sha256']), 64)
        self.assertIn('/v1.3.0+5/Iris-1.3.0.apk', data['apk_url'])

    def test_personal_library_is_rejected_inside_nested_zip(self):
        self.build(library=[{'titre': 'Une lecture privée'}])
        with self.assertRaisesRegex(ValueError, 'vide'):
            inspect_apk(self.apk)

    def test_personal_database_is_rejected(self):
        self.build(database=True)
        with self.assertRaisesRegex(ValueError, 'personnelle'):
            inspect_apk(self.apk)

    def test_unknown_apk_layout_is_rejected(self):
        with zipfile.ZipFile(self.apk, 'w') as z:
            z.writestr('unknown.txt', 'test')
        with self.assertRaisesRegex(ValueError, 'absentes'):
            inspect_apk(self.apk)


if __name__ == '__main__':
    unittest.main()
