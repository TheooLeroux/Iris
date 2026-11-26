"""Vérifier les filtres sans appel aux catalogues ni à l'API OpenAI."""
import copy
import io
import json
import tempfile
import unittest
from unittest.mock import Mock

from advice_filters import validate_filters
from app import handler
from storage import Store, canonical


class AdviceFilterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.store = Store(self.temp.name, library=[])
        self.source = canonical('anilist', {
            'id': 'filter-test', 'title': 'Filter test', 'country': 'KR',
            'status': 'RELEASING', 'chapters': 51,
            'genres': ['Fantasy', 'Romance'], 'tags': [], 'creators': ['Author'],
        })
        self.work = {'id': 'filters', 'title': 'Filter test', 'library': None,
                     'sources': [self.source]}

    def eligible(self, filters):
        self.store.filters = set(filters)
        return self.store.eligibility(self.work, 'discovery')[0]

    def test_chapter_boundaries_and_unknown_counts(self):
        for chapters, short, long, very_long in [
                ('', False, False, False), ('0', False, False, False),
                ('1', True, False, False), ('50', True, False, False),
                ('51', False, True, False), ('100', False, True, False),
                ('101', False, True, True)]:
            self.source['fields']['chapters'] = chapters
            for name, expected in [('short', short), ('long', long), ('very_long', very_long)]:
                with self.subTest(chapters=chapters, filter=name):
                    self.assertEqual(self.eligible([name]), expected)

    def test_publication_excludes_unknown_paused_cancelled_and_conflicts(self):
        for status in ['FINISHED', 'RELEASING', 'UNKNOWN', 'HIATUS', 'CANCELLED']:
            self.source['status'] = status
            self.assertEqual(self.eligible(['finished']), status == 'FINISHED')
            self.assertEqual(self.eligible(['ongoing']), status == 'RELEASING')
        self.source['status'] = 'RELEASING'
        other = copy.deepcopy(self.source)
        other['status'] = 'FINISHED'
        self.work['sources'].append(other)
        self.assertFalse(self.eligible(['ongoing']))
        self.assertFalse(self.eligible(['finished']))

    def test_country_must_be_confirmed_without_conflicting_source(self):
        self.assertTrue(self.eligible(['country:KR']))
        self.assertFalse(self.eligible(['country:JP']))
        self.source['country'] = 'UNKNOWN'
        self.assertFalse(self.eligible(['country:KR']))
        self.source['country'] = 'KR'
        other = copy.deepcopy(self.source)
        other['country'] = 'JP'
        self.work['sources'].append(other)
        self.assertFalse(self.eligible(['country:KR']))

    def test_genres_are_cumulative_and_accept_catalogue_tags(self):
        self.assertTrue(self.eligible(['genre:fantasy', 'genre:romance']))
        self.assertFalse(self.eligible(['genre:fantasy', 'genre:action']))
        self.source['genres'] = []
        self.source['tags'] = ['Sci-Fi', 'Slice of Life', 'Comédie']
        self.assertTrue(self.eligible(['genre:scifi', 'genre:slice_of_life', 'genre:comedy']))
        self.source['fields']['synopsis'] = 'Fantasy Romance Action'
        self.assertFalse(self.eligible(['genre:action']))

    def test_disagreeing_chapter_counts_do_not_certify_a_range(self):
        other = copy.deepcopy(self.source)
        other['fields']['chapters'] = '49'
        self.work['sources'].append(other)
        self.assertFalse(self.eligible(['long']))
        self.assertFalse(self.eligible(['short']))

    def test_api_accepts_new_filters_and_rejects_conflicts_or_unknown_values(self):
        application = Mock(port=8765, csrf='token')
        application.start.return_value = {'id': 'test'}
        request_type = handler(application)
        valid = ['ongoing', 'very_long', 'country:KR', 'genre:fantasy', 'genre:romance']
        for filters in [valid, ['short', 'long'], ['finished', 'ongoing'],
                        ['country:JP', 'country:KR'], ['genre:unknown'], [{}]]:
            with self.subTest(filters=filters):
                application.start.reset_mock()
                body = json.dumps({'prompt': 'Une lecture', 'filters': filters}).encode()
                request = request_type.__new__(request_type)
                request.path = '/api/advise'
                request.headers = {'Host': '127.0.0.1:8765', 'X-Reco-Token': 'token',
                                   'Content-Length': str(len(body))}
                request.rfile = io.BytesIO(body)
                request.send = Mock()
                request.do_POST()
                self.assertEqual(request.send.call_args.args[0], 202 if filters == valid else 400)
                if filters == valid:
                    application.start.assert_called_once_with('Une lecture', 'discovery', valid, None, 5, 'guided')
                else:
                    application.start.assert_not_called()

    def test_direct_filter_validation_rejects_invalid_shapes(self):
        for value in [None, 'finished', {'finished': True}, [None], ['unexpected']]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                validate_filters(value)
