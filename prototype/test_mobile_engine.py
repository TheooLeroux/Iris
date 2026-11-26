"""Persistance et exécution locale du moteur embarqué, sans serveur."""
import json
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch
from mobile_engine import Engine, NativeOpenAI

PROJECT = Path(__file__).resolve().parent.parent


class MobileEngineTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.engine = Engine(self.temp.name, PROJECT)

    def test_library_and_history_without_key_or_network(self):
        self.assertEqual(self.engine.request('history'), [])
        self.assertEqual(len(self.engine.store.library), 152)
        self.assertEqual(json.loads(self.engine.call('history', None, '')), {'data': []})

    def test_missing_key_does_not_create_job(self):
        response = json.loads(self.engine.call('advise', '{"prompt":"Romance"}', ''))
        self.assertIn('clé API', response['error'])
        self.assertEqual(self.engine.store.history(), [])

    def test_local_advice_persists_after_restart_without_secret(self):
        result = {'status': 'no_match', 'message': 'Test', 'recommendations': []}
        with patch('mobile_engine.Advisor.run', return_value=result):
            job = self.engine.start({'prompt': 'Romance GL', 'count': 2, 'filters': ['finished']}, 'secret-test')
            limit = time.monotonic() + 3
            while not self.engine.jobs[job['id']].get('saved') and time.monotonic() < limit:
                time.sleep(.01)
        restarted = Engine(self.temp.name, PROJECT)
        saved = restarted.request('history')[0]
        self.assertEqual(saved['result'], result)
        self.assertEqual(saved['filters'], ['finished'])
        self.assertNotIn('secret-test', json.dumps(saved))
        self.assertEqual(saved['status'], 'done')

    def test_interrupted_job_is_recovered(self):
        self.engine.store.save_run({'id': 'interrupted', 'prompt': 'Fantasy', 'scope': 'discovery', 'status': 'running'})
        restarted = Engine(self.temp.name, PROJECT)
        self.assertEqual(restarted.request('history')[0]['status'], 'error')
        self.assertIn('fermeture', restarted.request('history')[0]['error'])

    def test_mobile_calls_catalogues_directly(self):
        with patch('mobile_engine.reading_links.search', return_value={'works': []}) as search:
            result = self.engine.request('reading/search?title=Une+%C5%93uvre')
        self.assertEqual(result, {'works': []})
        search.assert_called_once_with(self.engine.catalogues, 'Une œuvre')

    def test_no_key_limits_reading_to_public_catalogue(self):
        with patch('mobile_engine.reading_links.reading_links', return_value={'warnings': []}) as search:
            result = self.engine.request('reading/chapters?id=test&chapters=41')
        self.assertIsNone(search.call_args.args[3])
        self.assertIn('clé API', result['warnings'][0])

    def test_unknown_filters_are_rejected_before_job(self):
        with self.assertRaises(ValueError):
            self.engine.start({'prompt': 'Fantasy', 'filters': ['invented']}, 'test')
        self.assertEqual(self.engine.jobs, {})

    def test_android_transport_keeps_payload_and_redacts_api_errors(self):
        from unittest.mock import Mock
        transport = Mock()
        transport.post.return_value = json.dumps({'status': 200, 'body': '{"output":[]}'})
        client = NativeOpenAI('sk-secret-test', transport)
        self.assertEqual(client.send({'model': 'test', 'input': 'Œuvre'}), {'output': []})
        self.assertEqual(json.loads(transport.post.call_args.args[0])['input'], 'Œuvre')
        self.assertEqual(transport.post.call_args.args[1], 'sk-secret-test')
        transport.post.return_value = json.dumps({'status': 401, 'body': json.dumps({'error': {'message': 'Invalid sk-secret-test'}})})
        with self.assertRaises(ValueError) as error:
            client.send({})
        self.assertNotIn('sk-secret-test', str(error.exception))
        self.assertIn('401', str(error.exception))
        transport.post.return_value = '{"network_error":true}'
        with self.assertRaises(OSError):
            client.send({})


if __name__ == '__main__':
    unittest.main()
