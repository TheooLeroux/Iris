import copy
import json
from pathlib import Path
import tempfile
import unittest

from mangatime import MangaTime

ID = '12345678-1234-1234-1234-123456789abc'
WORK = {'title': 'Une recommandation'}


class Transport:
    def __init__(self):
        self.owner = 'account-one'
        self.data = {'id': ID, 'title': 'Une recommandation', 'user_related': None}
        self.calls = []
        self.fail_write = False
        self.fail_after_write = False

    def account(self):
        return self.owner

    def request(self, method, path):
        self.calls.append((method, path))
        if method == 'GET':
            body = {'data': copy.deepcopy(self.data)}
            if '/search?' in path:
                body = {'data': {'manga': [copy.deepcopy(self.data)]}}
            return json.dumps({'status': 200, 'body': json.dumps(body)})
        if self.fail_write:
            return json.dumps({'status': 403})
        self.data['user_related'] = {'status': 4, 'progress': 0, 'rating': None} if method == 'POST' else None
        if self.fail_after_write:
            return json.dumps({'status': 0})
        return json.dumps({'status': 204, 'body': ''})


class MangaTimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.network = Transport()
        self.client = MangaTime(Path(self.temp.name) / 'test.sqlite3', self.network)

    def add(self):
        return self.client.set_planned(WORK, ID, True)

    def writes(self):
        return [c for c in self.network.calls if c[0] != 'GET']

    def test_state_without_link_does_not_contact_service(self):
        self.assertFalse(self.client.state(WORK)['added'])
        self.assertEqual(self.network.calls, [])

    def test_add_remove_and_persistence(self):
        self.assertTrue(self.add()['can_remove'])
        restarted = MangaTime(self.client.database, self.network)
        self.assertTrue(restarted.state(WORK)['can_remove'])
        rows = restarted.library([])
        self.assertEqual(rows[0]['statut'], 'À lire')
        self.assertFalse(restarted.set_planned(WORK, ID, False)['added'])
        self.assertEqual(restarted.library(rows), [])
        self.assertEqual([c[0] for c in self.writes()], ['POST', 'DELETE'])

    def test_duplicate_add_is_idempotent(self):
        self.add()
        self.add()
        self.assertEqual(len(self.writes()), 1)

    def test_existing_backlog_is_not_owned(self):
        self.network.data['user_related'] = {'status': 4}
        self.assertFalse(self.add()['can_remove'])
        with self.assertRaises(ValueError):
            self.client.set_planned(WORK, ID, False)
        self.assertEqual(self.writes(), [])

    def test_existing_started_reading_is_never_changed(self):
        self.network.data['user_related'] = {'status': 0}
        self.assertEqual(self.add()['status'], 'En cours')
        self.assertEqual(self.writes(), [])

    def test_remove_rechecks_live_status(self):
        self.add()
        self.network.data['user_related']['status'] = 0
        with self.assertRaisesRegex(ValueError, 'modifiée'):
            self.client.set_planned(WORK, ID, False)
        self.assertEqual(len(self.writes()), 1)

    def test_remove_preserves_progress_annotations_ratings_and_lists(self):
        self.add()
        for field, value in [('progress', 1), ('last_chapter_number', 1), ('rating', 4),
                             ('private_note', 'une note'), ('custom_list_ids', ['id'])]:
            self.network.data['user_related'] = {'status': 4, field: value}
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.client.set_planned(WORK, ID, False)
        self.assertEqual(len(self.writes()), 1)

    def test_lost_add_response_recovers_without_duplicate_write(self):
        self.network.fail_after_write = True
        with self.assertRaises(ValueError):
            self.add()
        self.assertTrue(self.client.state(WORK)['can_remove'])
        self.assertEqual(len(self.writes()), 1)

    def test_lost_remove_response_recovers(self):
        self.add()
        self.network.fail_after_write = True
        with self.assertRaises(ValueError):
            self.client.set_planned(WORK, ID, False)
        self.assertFalse(self.client.state(WORK)['added'])

    def test_refused_write_never_reports_success(self):
        self.network.fail_write = True
        with self.assertRaises(ValueError):
            self.add()
        self.assertFalse(self.client.state(WORK)['added'])
        self.assertEqual(self.client.library([]), [])

    def test_sessions_are_isolated(self):
        self.add()
        self.network.owner = 'another-account'
        self.assertFalse(self.client.state(WORK)['added'])
        self.assertEqual(self.client.library([]), [])
        with self.assertRaises(ValueError):
            self.client.set_planned(WORK, ID, False)
        self.assertEqual(len(self.writes()), 1)

    def test_invalid_id_or_unknown_status_never_writes(self):
        with self.assertRaises(ValueError):
            self.client.set_planned(WORK, '../something', True)
        self.network.data['user_related'] = {'status': 99}
        with self.assertRaises(ValueError):
            self.add()
        self.assertEqual(self.writes(), [])

    def test_search_only_returns_manga_candidates(self):
        results = self.client.search(WORK)
        self.assertEqual(results, [{'id': ID, 'title': WORK['title'], 'status': None}])
        self.assertEqual(self.writes(), [])

    def test_real_api_empty_user_preferences_are_not_library_membership(self):
        self.network.data['user_related'] = {'custom_list_ids': [], 'recommendation_feedback': None}
        self.assertIsNone(self.client.search(WORK)[0]['status'])
        self.assertTrue(self.add()['can_remove'])

    def test_refused_attempt_does_not_claim_a_later_manual_add(self):
        self.network.fail_write = True
        with self.assertRaises(ValueError):
            self.add()
        self.network.data['user_related'] = {'status': 4}
        self.assertFalse(self.client.state(WORK)['can_remove'])

    def test_new_export_started_reading_survives_stale_local_add(self):
        self.add()
        rows = [{'titre': WORK['title'], 'statut': 'En cours', 'note': 4}]
        self.assertEqual(self.client.library(rows), rows)


if __name__ == '__main__':
    unittest.main()
