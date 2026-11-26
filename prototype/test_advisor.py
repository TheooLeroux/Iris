"""Régressions sur les risques réels : homonymes, historique, critères et preuves."""
import copy
import io
import json
import tempfile
import threading
import unittest
from unittest.mock import patch
from pathlib import Path

from agent import Advisor, validate_advice, validate_result
from app import DEFAULT_SCOPE, feedback_candidate, handler
from storage import Store, canonical, norm
from catalogue_clients import Catalogues


class AdvisorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.store = Store(Path(cls.temp.name))
        cls.reference = next(w for w in cls.store.works.values() if w['title'] == 'Solo Leveling')

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def candidate(self, suffix='a', **kwargs):
        row = {'id': 'test-' + suffix, 'title': 'Test original ' + suffix, 'aliases': [],
               'url': 'https://anilist.co/manga/123', 'country': 'KR', 'status': 'FINISHED',
               'tags': [{'name': 'Romance'}], 'genres': ['Romance'], 'synopsis': 'A romantic story.',
               'creators': ['Test author ' + suffix]}
        row.update(kwargs)
        return self.store.register(canonical('anilist', row))

    def result(self, work):
        return {'status': 'recommendation', 'candidate_id': work['id'], 'message': 'Conseil', 'why_this': 'Raison',
                'reservations': [], 'personal_basis': [{'library_id': self.reference['id'], 'explanation': 'Comparaison'}],
                'checks': [], 'evidence': [{'source_id': work['sources'][0]['id'], 'field': 'tags', 'quote': 'Romance'}]}

    def errors(self, result, work, constraints=None):
        return validate_result(result, {'constraints': constraints or []}, self.store, 'discovery', {work['id']})

    def test_import_all_titles_and_reviewed_homonyms(self):
        self.assertEqual(len(self.store.library), 152)
        hana = next(w for w in self.store.works.values() if w['title'] == 'Hana ni Arashi')
        ids = {s['id'] for s in hana['sources']}
        self.assertIn('mangaupdates:232570473', ids)
        self.assertNotIn('mangaupdates:60654208657', ids)
        play = next(w for w in self.store.works.values() if w['title'] == "Let's Play")
        self.assertNotIn('anilist:46275', {s['id'] for s in play['sources']})

    def test_discovery_excludes_every_library_title_including_planned(self):
        library = [w for w in self.store.works.values() if w['library']]
        self.assertEqual(len(library), 152)
        self.assertEqual(sum(w['library']['statut'] == 'À lire' for w in library), 25)
        for work in library:
            with self.subTest(title=work['title']):
                self.assertFalse(self.store.eligibility(work, 'discovery')[0])

    def test_planned_title_remains_excluded_under_its_catalogue_ids(self):
        work = next(w for w in self.store.works.values() if w['library'] and w['library']['statut'] == 'À lire')
        for source in list(work['sources']):
            incoming = copy.deepcopy(source)
            incoming['title'] = 'Un titre traduit différent'
            recognized = self.store.register(incoming)
            self.assertEqual(recognized['id'], work['id'])
            self.assertFalse(self.store.eligibility(recognized, 'discovery')[0])

    def test_planned_title_alias_with_unknown_creator_is_conservatively_excluded(self):
        work = next(w for w in self.store.works.values() if w['library'] and w['library']['statut'] == 'À lire')
        source = canonical('anilist', {'id': 'planned-alias-unknown', 'title': 'Traduction nouvelle',
                           'aliases': [work['title']], 'creators': []})
        candidate = self.store.register(source)
        self.assertTrue(candidate['possible_library_overlap'])
        self.assertFalse(self.store.eligibility(candidate, 'discovery')[0])

    def test_http_defaults_to_discovery_and_preserves_explicit_backlog(self):
        self.assertEqual(DEFAULT_SCOPE, 'discovery')
        application = unittest.mock.Mock(port=8765, csrf='test-token')
        application.start.return_value = {'id': 'test'}
        request_type = handler(application)
        for explicit in (None, 'backlog'):
            application.start.reset_mock()
            payload = {'prompt': 'Une romance GL'}
            if explicit:
                payload['scope'] = explicit
            body = json.dumps(payload).encode()
            request = request_type.__new__(request_type)
            request.path = '/api/advise'
            request.headers = {'Host': '127.0.0.1:8765', 'X-Reco-Token': 'test-token', 'Content-Length': str(len(body))}
            request.rfile = io.BytesIO(body)
            request.send = unittest.mock.Mock()
            request.do_POST()
            application.start.assert_called_once_with('Une romance GL', explicit or 'discovery')
            request.send.assert_called_once_with(202, {'id': 'test'})

    def test_unicode_kept(self):
        self.assertTrue(norm('별'))
        self.assertNotEqual(norm('별'), norm('別'))
        self.assertEqual(norm('Mage & Demon Queen'), norm('Mage and Demon Queen'))

    def test_cover_uses_only_the_requested_catalogue_record(self):
        client = Catalogues(self.store, Path(self.temp.name))
        url = 'https://cdn.mangaupdates.com/image/i1.jpg'
        with patch.object(client, 'fetch', return_value={'series_id': 8, 'image': {'url': {'original': url}}}):
            self.assertIsNone(client.cover_url('mangaupdates:9'))
            self.assertEqual(client.cover_url('mangaupdates:8'), url)

    def test_cover_uses_mangadex_cover_relation_and_valid_id(self):
        client = Catalogues(self.store, Path(self.temp.name))
        key = 'ac2a3e07-ab94-438e-aab8-986e0124b85f'
        row = {'id': key, 'relationships': [{'type': 'author'}, {'type': 'cover_art', 'attributes': {'fileName': 'a.jpg'}}]}
        with patch.object(client, 'fetch', return_value={'data': row}) as fetch:
            self.assertEqual(client.cover_url('mangadex:'+key), f'https://uploads.mangadex.org/covers/{key}/a.jpg.256.jpg')
            self.assertIsNone(client.cover_url('mangadex:un-titre'))
            self.assertEqual(fetch.call_count, 1)

    def test_anilist_routes_genres_and_themes_to_correct_filters(self):
        client = Catalogues(self.store, Path(self.temp.name))
        with patch.object(client, 'taxonomy', return_value={'genres': ['Fantasy', 'Romance'], 'tags': ['Female Protagonist']}), patch.object(client, 'fetch', return_value={'data': {'Page': {'media': []}}}) as fetch:
            client.search('anilist', '', ['Female Protagonist', 'Fantasy'], ['Romance'], 'KR', True)
            payload = fetch.call_args.args[2]
            self.assertEqual(payload['variables']['genres'], ['Fantasy'])
            self.assertEqual(payload['variables']['tags'], ['Female Protagonist'])
            self.assertEqual(payload['variables']['excluded_genres'], ['Romance'])
            self.assertIn('status:FINISHED', payload['query'])

    def test_admissible_work_has_no_contradictory_rejection_reason(self):
        work = self.candidate('reason')
        self.assertEqual(self.store.eligibility(work, 'discovery'), (True, ''))
        for item in self.store.works.values():
            if item['library'] and item['library']['statut'] == 'À lire':
                self.assertEqual(self.store.eligibility(item, 'backlog'), (True, ''))
                break

    def test_library_scope_is_proved_by_server_without_public_quote(self):
        work = self.candidate('scope-proof')
        result = self.result(work)
        result['checks'] = [{'constraint_id': 'new', 'verdict': 'supported', 'explanation': 'Contrôle local', 'evidence': []}]
        constraint = {'id': 'new', 'description': 'Nouvelle découverte', 'kind': 'library_scope', 'priority': 'strict', 'value': 'discovery'}
        self.assertEqual(self.errors(result, work, [constraint]), [])

    def test_feedback_retains_the_request_that_failed(self):
        work = self.candidate('context-feedback')
        self.store.save_run({'id': 'feedback-context', 'prompt': 'Une romance GL', 'scope': 'unread'})
        self.store.add_feedback('feedback-context', work['id'], 'off_topic', 'Trop de combats')
        feedback = next(f for f in self.store.feedback() if f['run_id'] == 'feedback-context')
        self.assertEqual(feedback['request_prompt'], 'Une romance GL')

    def test_finished_and_paused_excluded_from_unread(self):
        for work in self.store.works.values():
            if work['library'] and work['library']['statut'] in ('Terminé', 'En pause', 'En cours', 'Abandonné'):
                self.assertFalse(self.store.eligibility(work, 'unread')[0])

    def test_backlog_is_25_not_liked(self):
        backlog = [w for w in self.store.works.values() if self.store.eligibility(w, 'backlog')[0]]
        self.assertEqual(len(backlog), 25)
        work = backlog[0]
        result = self.result(self.candidate('planned'))
        result['personal_basis'] = [{'library_id': work['id'], 'explanation': 'Tu aimes'}]
        self.assertTrue(any('non lue' in x for x in self.errors(result, self.store.get(result['candidate_id']))))

    def test_paused_high_ratings_kept_as_positive_data(self):
        positive = [w for w in self.store.works.values() if w['library'] and w['library']['statut'] == 'En pause' and (w['library']['note'] or 0) >= 4]
        self.assertEqual(len(positive), 34)
        self.assertEqual(self.store.taste_card(positive[0])['library']['note'], positive[0]['library']['note'])

    def test_exact_source_id_recognizes_alternate_title(self):
        source = self.reference['sources'][0]
        changed = copy.deepcopy(source)
        changed['title'] = 'Un autre titre traduit'
        self.assertEqual(self.store.register(changed)['id'], self.reference['id'])

    def test_same_title_different_creator_not_silently_merged(self):
        row = canonical('anilist', {'id': 'homonym-test', 'title': self.reference['title'],
                        'aliases': [self.reference['title']], 'creators': ['A different creator']})
        work = self.store.register(row)
        self.assertNotEqual(work['id'], self.reference['id'])
        self.assertFalse(self.store.eligibility(work, 'discovery')[0])

    def test_new_candidate_can_pass(self):
        work = self.candidate('valid')
        self.assertEqual(self.errors(self.result(work), work), [])

    def test_fabricated_evidence_rejected(self):
        work = self.candidate('evidence')
        result = self.result(work)
        result['evidence'][0]['quote'] = 'Happily ever after'
        self.assertTrue(self.errors(result, work))
        result['evidence'][0] = {'source_id': 'anilist:invented', 'field': 'tags', 'quote': 'Romance'}
        self.assertTrue(self.errors(result, work))

    def test_uninspected_candidate_rejected(self):
        work = self.candidate('inspect')
        self.assertTrue(validate_result(self.result(work), {'constraints': []}, self.store, 'discovery', set()))

    def test_unknown_candidate_rejected(self):
        work = self.candidate('unknown')
        result = self.result(work)
        result['candidate_id'] = 'invented:1234'
        self.assertTrue(self.errors(result, work))

    def test_mandatory_unknown_not_treated_as_match(self):
        work = self.candidate('uncertain')
        result = self.result(work)
        result['checks'] = [{'constraint_id': 'no_harem', 'verdict': 'uncertain', 'explanation': 'Pas de tag', 'evidence': []}]
        self.assertTrue(self.errors(result, work, [{'id': 'no_harem', 'description': 'Sans harem', 'kind': 'excluded_topic', 'priority': 'strict', 'value': 'Harem'}]))

    def test_conflicting_or_wrong_objective_facts_rejected(self):
        work = self.candidate('wrong-country', country='JP')
        result = self.result(work)
        result['checks'] = [{'constraint_id': 'kr', 'verdict': 'supported', 'explanation': 'Coréen',
                            'evidence': [{'source_id': work['sources'][0]['id'], 'field': 'country', 'quote': 'JP'}]}]
        constraint = {'id': 'kr', 'description': 'Manhwa', 'kind': 'country', 'priority': 'strict', 'value': 'KR'}
        self.assertTrue(self.errors(result, work, [constraint]))
        work = self.candidate('status', status='RELEASING')
        result = self.result(work)
        result['checks'] = [{'constraint_id': 'done', 'verdict': 'supported', 'explanation': 'Terminé',
                            'evidence': [{'source_id': work['sources'][0]['id'], 'field': 'status', 'quote': 'RELEASING'}]}]
        self.assertTrue(self.errors(result, work, [{'id': 'done', 'description': 'Terminé', 'kind': 'finished', 'priority': 'strict', 'value': 'true'}]))

    def test_missing_constraint_rejected(self):
        work = self.candidate('missing')
        self.assertTrue(self.errors(self.result(work), work, [{'id': 'gl', 'description': 'GL', 'kind': 'topic', 'priority': 'strict', 'value': 'GL'}]))

    def test_already_read_feedback_persists_after_restart(self):
        work = self.candidate('read')
        self.assertTrue(self.store.eligibility(work, 'discovery')[0])
        self.store.add_feedback('test', work['id'], 'already_read', 'Lu ailleurs')
        self.assertFalse(self.store.eligibility(work, 'discovery')[0])
        reloaded = Store(Path(self.temp.name))
        self.assertFalse(reloaded.eligibility(reloaded.get(work['id']), 'discovery')[0])

    def test_off_topic_feedback_is_not_a_universal_genre_ban(self):
        work = self.candidate('off-topic')
        self.store.add_feedback('test', work['id'], 'off_topic', 'Je voulais de la romance cette fois.')
        self.assertTrue(self.store.eligibility(work, 'discovery')[0])

    def test_audit_original_remains_complete(self):
        vowrune = next(w for w in self.store.works.values() if w['title'] == 'Vowrune - GL')
        self.assertEqual(len(vowrune['sources']), 3)
        self.assertEqual(vowrune['sources'][0]['catalogue'], 'publication')

    def batch(self, suffix='batch'):
        works = [self.candidate(suffix+str(i)) for i in range(5)]
        return works, {'status': 'recommendation', 'message': 'Cinq choix', 'reservations': [],
                       'recommendations': [{k:v for k,v in self.result(w).items() if k != 'status'} for w in works]}

    def test_requested_count_and_absolute_mode(self):
        works, result = self.batch('requested-number')
        inspected = {w['id'] for w in works}
        for count in range(1,6):
            exact = dict(result,recommendations=result['recommendations'][:count])
            self.assertEqual(validate_advice(exact, {'constraints':[]}, self.store, 'discovery', inspected, count=count), [])
            if count < 5:
                self.assertTrue(validate_advice(result, {'constraints':[]}, self.store, 'discovery', inspected, count=count))
        result['recommendations'][-1]['fit'] = 'exploratory'
        self.assertIn('Le mode obligatoire exige des propositions étayées.', validate_advice(result, {'constraints':[]}, self.store, 'discovery', inspected, mode='absolute'))

    def test_hard_filters_and_past_selections(self):
        work = self.candidate('old-advice')
        store = Store(Path(self.temp.name), filters=['finished','long'])
        self.assertFalse(store.eligibility(work,'discovery')[0])
        work['sources'][0]['fields']['chapters'] = '50'
        self.assertFalse(store.eligibility(work,'discovery')[0])
        work['sources'][0]['fields']['chapters'] = '51'
        self.assertTrue(store.eligibility(work,'discovery')[0])
        store.save_run({'id':'old','status':'done','prompt':'lecture','scope':'discovery','result':{'status':'recommendation','recommendations':[{'candidate_id':work['id'],'work':store.card(work,full=True)}]}})
        reloaded = Store(Path(self.temp.name))
        self.assertFalse(reloaded.eligibility(work,'discovery')[0])
        self.assertFalse(reloaded.eligibility(self.candidate('same-story',aliases=[work['title']],creators=work['sources'][0]['creators']),'discovery')[0])

    def test_five_valid_choices_pass(self):
        works, result = self.batch('five')
        self.assertEqual(validate_advice(result, {'constraints': []}, self.store, 'discovery', {w['id'] for w in works}), [])

    def test_empty_or_overfull_recommendations_rejected(self):
        works, result = self.batch('count')
        for count in (0, 6):
            with self.subTest(count=count):
                changed = copy.deepcopy(result)
                changed['recommendations'] = (changed['recommendations'] * 2)[:count]
                self.assertTrue(validate_advice(changed, {'constraints': []}, self.store, 'discovery', {w['id'] for w in works}))

    def test_short_selection_is_accepted_when_explained(self):
        works, result = self.batch('short')
        for count in (1, 4):
            changed = copy.deepcopy(result)
            changed['recommendations'] = changed['recommendations'][:count]
            changed['reservations'] = ['Les autres pistes n’ont pas assez de preuves.']
            self.assertEqual(validate_advice(changed, {'constraints': []}, self.store, 'discovery', {w['id'] for w in works}), [])

    def setting_case(self, suffix, fit='strong', strict=False, synopsis='An elven kingdom is threatened by a magical war.'):
        work = self.candidate(suffix, synopsis=synopsis)
        source_id = work['sources'][0]['id']
        evidence = [{'source_id': source_id, 'field': 'synopsis', 'quote': 'An elven kingdom'}] if synopsis else []
        result = self.result(work)
        result.update(fit=fit, exploration_reason='Une piste proche, à confirmer.' if fit == 'exploratory' else '',
                      reservations=['Le décor précis reste incertain.'] if fit == 'exploratory' else [],
                      setting_assessment={'observed_world': 'Royaume merveilleux', 'match': 'aligned' if fit == 'strong' else 'uncertain',
                                          'explanation': 'Lecture du récit', 'evidence': evidence})
        result['checks'] = [{'constraint_id': 'world', 'verdict': 'supported' if fit == 'strong' else 'uncertain', 'explanation': 'Le décor', 'evidence': evidence}]
        contract = {'constraints': [{'id': 'world', 'description': 'Monde de fantasy', 'kind': 'setting', 'value': 'secondary world', 'priority': 'strict' if strict else 'core'}]}
        return work, result, contract

    def test_setting_requires_narrative_not_generic_genre(self):
        work, result, contract = self.setting_case('genre-proof')
        tag = {'source_id': work['sources'][0]['id'], 'field': 'tags', 'quote': 'Romance'}
        result['checks'][0]['evidence'] = [tag]
        result['setting_assessment']['evidence'] = [tag]
        errors = validate_result(result, contract, self.store, 'discovery', {work['id']})
        self.assertTrue(any('passage narratif' in e for e in errors))

    def test_narrative_can_support_setting(self):
        work, result, contract = self.setting_case('narrative-proof')
        self.assertEqual(validate_result(result, contract, self.store, 'discovery', {work['id']}), [])

    def test_different_or_uncertain_setting_not_strong(self):
        work, result, contract = self.setting_case('world-mismatch')
        result['setting_assessment']['match'] = 'different'
        errors = validate_result(result, contract, self.store, 'discovery', {work['id']})
        self.assertTrue(any('analyse du décor' in e for e in errors))

    def test_exploration_allows_limited_uncertainty_after_research(self):
        work, result, contract = self.setting_case('tentative', fit='exploratory')
        self.assertEqual(validate_result(result, contract, self.store, 'discovery', {work['id']}, {work['id']}), [])
        self.assertTrue(validate_result(result, contract, self.store, 'discovery', {work['id']}))

    def test_explicit_strict_setting_still_blocks_uncertain_exploration(self):
        work, result, contract = self.setting_case('strict-world', fit='exploratory', strict=True)
        self.assertTrue(validate_result(result, contract, self.store, 'discovery', {work['id']}, {work['id']}))

    def test_exploration_never_hides_a_violated_core_criterion(self):
        work, result, contract = self.setting_case('violated-world', fit='exploratory')
        result['checks'][0]['verdict'] = 'violated'
        self.assertTrue(validate_result(result, contract, self.store, 'discovery', {work['id']}, {work['id']}))

    def test_missing_synopsis_cannot_be_strong_even_after_enrichment(self):
        work, result, contract = self.setting_case('no-synopsis', synopsis='')
        errors = validate_result(result, contract, self.store, 'discovery', {work['id']}, {work['id']})
        self.assertTrue(any('sans synopsis' in e for e in errors))

    def test_missing_synopsis_may_be_an_explicit_exploration_after_attempt(self):
        work, result, contract = self.setting_case('poor-explore', fit='exploratory', synopsis='')
        self.assertTrue(validate_result(result, contract, self.store, 'discovery', {work['id']}, {work['id']}))
        source = canonical('mangaupdates', {'id': 'partial', 'title': work['title'], 'genres': ['Fantasy']})
        work['sources'].append(source)
        result['checks'][0]['evidence'] = [{'source_id': source['id'], 'field': 'genres', 'quote': 'Fantasy'}]
        self.assertEqual(validate_result(result, contract, self.store, 'discovery', {work['id']}, {work['id']}), [])

    def test_optional_setting_can_differ_while_core_is_supported(self):
        work, result, contract = self.setting_case('preference')
        contract['constraints'][0]['priority'] = 'preference'
        result['checks'][0]['verdict'] = 'violated'
        result['setting_assessment']['match'] = 'different'
        self.assertEqual(validate_result(result, contract, self.store, 'discovery', {work['id']}), [])

    def test_two_uncertain_core_criteria_disqualify_exploration(self):
        work, result, contract = self.setting_case('uncertain-pair', fit='exploratory')
        contract['constraints'].append(dict(contract['constraints'][0], id='character', kind='topic'))
        result['checks'].append(dict(result['checks'][0], constraint_id='character'))
        errors = validate_result(result, contract, self.store, 'discovery', {work['id']}, {work['id']})
        self.assertTrue(any('un seul critère central' in e for e in errors))

    def test_exploration_can_confirm_setting_while_another_criterion_is_uncertain(self):
        work, result, contract = self.setting_case('aligned-exploration')
        result.update(fit='exploratory', exploration_reason='Indices sur le personnage', reservations=['Son rôle reste incertain.'])
        contract['constraints'].append(dict(contract['constraints'][0], id='character', kind='topic'))
        result['checks'].append(dict(result['checks'][0], constraint_id='character', verdict='uncertain'))
        self.assertEqual(validate_result(result, contract, self.store, 'discovery', {work['id']}, {work['id']}), [])

    def test_cache_search_uses_aliases_deduplicates_and_respects_scope(self):
        work = self.candidate('cache-one', aliases=['Rare alternate query'])
        duplicate = dict(work, id='test:duplicate-cached')
        self.store.works[duplicate['id']] = duplicate
        self.assertEqual([w['id'] for w in self.store.candidates('Rare alternate query', 'discovery')], [work['id']])
        planned = next(w for w in self.store.works.values() if w['library'] and w['library']['statut'] == 'À lire')
        self.assertNotIn(planned['id'], [w['id'] for w in self.store.candidates(planned['title'], 'discovery')])

    def test_only_one_exploratory_choice_at_end(self):
        works, result = self.batch('two-explores')
        for choice in result['recommendations'][-2:]:
            choice.update(fit='exploratory', exploration_reason='Piste à tester', reservations=['Thème incertain'])
        errors = validate_advice(result, {'constraints': []}, self.store, 'discovery', {w['id'] for w in works}, {w['id'] for w in works})
        self.assertTrue(any('Une seule piste exploratoire' in e for e in errors))

    def test_enrichment_accepts_same_title_and_creator_not_homonyms(self):
        target = self.candidate('enrich-target', synopsis='')
        source = canonical('mangaupdates', {'id': 'enrich-other', 'title': target['title'], 'aliases': [target['title']],
                          'creators': target['sources'][0]['creators'], 'synopsis': 'An elven kingdom.'})
        other = {'id': 'other-work', 'title': target['title'], 'library': None, 'identity': 'fiche_catalogue', 'sources': [source]}
        client = Catalogues(self.store, Path(self.temp.name))
        with patch.object(client, 'search', side_effect=[[other], []]):
            report = client.enrich(target['id'], 'Décor manquant')
        self.assertTrue(report['quality']['has_synopsis'])
        self.assertIn('mangaupdates:enrich-other', report['confirmed_sources'])
        wrong = copy.deepcopy(other)
        wrong['sources'][0]['creators'] = ['Un autre auteur']
        self.assertFalse(client.same_identity(target, wrong))

    def test_enrichment_tries_native_title_and_does_not_merge_unconfirmed_results(self):
        target = self.candidate('native-search', title='A rare English title', aliases=['とても珍しい題名'], synopsis='')
        other = self.candidate('unrelated-title')
        client = Catalogues(self.store, Path(self.temp.name))
        with patch.object(client, 'search', return_value=[other]) as search:
            report = client.enrich(target['id'], 'Synopsis absent')
        self.assertTrue(any(call.args[1] == 'とても珍しい題名' for call in search.call_args_list))
        self.assertEqual(report['confirmed_sources'], [])
        self.assertTrue(report['unconfirmed_matches'])

    def test_existing_catalogue_record_can_gain_missing_synopsis(self):
        work = self.candidate('refresh-poor', synopsis='')
        updated = copy.deepcopy(work['sources'][0])
        updated['fields']['synopsis'] = 'Un récit dans un royaume magique.'
        self.store.register(updated)
        self.assertEqual(work['sources'][0]['fields']['synopsis'], updated['fields']['synopsis'])

    def test_enrichment_preserves_history_ids_after_restart(self):
        first = self.candidate('persist-first')
        second = self.candidate('persist-second')
        self.store.attach_verified_sources(first, second)
        reloaded = Store(Path(self.temp.name))
        self.assertIsNotNone(reloaded.get(first['id']))
        self.assertIsNotNone(reloaded.get(second['id']))

    def test_poor_inspection_automatically_attempts_enrichment(self):
        work = self.candidate('auto-enrich', synopsis='')
        report = {'candidate_id': work['id'], 'reason': 'Synopsis absent',
                  'attempts': [{'source': 'anilist', 'title': work['title'], 'results': 0}],
                  'confirmed_sources': [], 'quality': {'has_synopsis': False}, 'work': self.store.card(work, full=True)}
        catalogues = unittest.mock.Mock()
        catalogues.enrich.return_value = report
        catalogues.search.return_value = []
        calls = [{'type': 'function_call', 'name': 'set_request', 'call_id': 'set', 'arguments': json.dumps({'summary': 'Demande', 'constraints': []})},
                 {'type': 'function_call', 'name': 'local_candidates', 'call_id': 'cache', 'arguments': json.dumps({'query': 'auto-enrich'})},
                 {'type': 'function_call', 'name': 'catalogue_search', 'call_id': 'public', 'arguments': json.dumps({'source': 'anilist', 'title': work['title']})},
                 {'type': 'function_call', 'name': 'inspect_work', 'call_id': 'inspect', 'arguments': json.dumps({'candidate_id': work['id']})}]
        final = {'status': 'no_match', 'message': 'La fiche reste trop pauvre.', 'reservations': [], 'recommendations': []}
        client = unittest.mock.Mock()
        client.response.side_effect = [{'output': calls}, {'output': [{'type': 'message', 'content': [{'type': 'output_text', 'text': json.dumps(final)}]}]}]
        job = {'prompt': 'Demande', 'scope': 'discovery', 'cancel': threading.Event(), 'input_tokens': 0, 'output_tokens': 0, 'cost_usd': 0}
        completed = Advisor(self.store, catalogues, client).run(job, lambda _: None)
        self.assertEqual(catalogues.enrich.call_count, 1)
        self.assertEqual(completed['enrichment_reports'][0]['candidate_id'], work['id'])
        self.assertNotIn('work', completed['enrichment_reports'][0])

    def test_duplicate_in_five_rejected(self):
        works, result = self.batch('duplicate')
        result['recommendations'][-1] = result['recommendations'][0]
        errors = validate_advice(result, {'constraints': []}, self.store, 'discovery', {w['id'] for w in works})
        self.assertTrue(any('doublon' in e for e in errors))

    def test_alternate_catalogue_entry_cannot_count_as_another_work(self):
        works, result = self.batch('alias-duplicate')
        duplicate = copy.deepcopy(works[0])
        duplicate['id'] = 'test:separate-entry'
        self.store.works[duplicate['id']] = duplicate
        result['recommendations'][-1] = {**result['recommendations'][0], 'candidate_id': duplicate['id']}
        errors = validate_advice(result, {'constraints': []}, self.store, 'discovery', {w['id'] for w in works} | {duplicate['id']})
        self.assertTrue(any('doublon' in e for e in errors))

    def test_each_of_five_must_have_real_evidence(self):
        works, result = self.batch('evidence-five')
        result['recommendations'][3]['evidence'][0]['quote'] = 'Citation inventée'
        errors = validate_advice(result, {'constraints': []}, self.store, 'discovery', {w['id'] for w in works})
        self.assertTrue(any('Proposition 4' in e for e in errors))

    def test_no_match_never_contains_unverified_choices(self):
        _, result = self.batch('no-match-five')
        result['status'] = 'no_match'
        self.assertTrue(validate_advice(result, {'constraints': []}, self.store, 'discovery', set()))
        result['recommendations'] = []
        self.assertEqual(validate_advice(result, {'constraints': []}, self.store, 'discovery', set()), [])

    def test_feedback_targets_only_one_of_the_five(self):
        works, result = self.batch('feedback-five')
        job = {'result': result}
        self.assertEqual(feedback_candidate(job, works[2]['id']), works[2]['id'])
        for invalid in (None, 'invented:foreign'):
            with self.assertRaises(ValueError):
                feedback_candidate(job, invalid)
        legacy = {'result': self.result(works[0])}
        self.assertEqual(feedback_candidate(legacy, None), works[0]['id'])

    def test_tool_loop_inspects_and_enriches_all_five(self):
        works = [w for w in self.store.works.values() if w['library'] and w['library']['statut'] == 'À lire'][:5]
        choices = []
        calls = [{'type': 'function_call', 'name': 'set_request', 'call_id': 'request',
                  'arguments': json.dumps({'summary': 'Cinq lectures', 'constraints': []})}]
        for i, work in enumerate(works):
            choice = {k:v for k,v in self.result(work).items() if k != 'status'}
            source = work['sources'][0]
            choice['evidence'] = [{'source_id': source['id'], 'field': 'title', 'quote': source['fields']['title'][:80]}]
            choices.append(choice)
            calls.append({'type': 'function_call', 'name': 'inspect_work', 'call_id': 'inspect'+str(i),
                          'arguments': json.dumps({'candidate_id': work['id']})})
        result = {'status': 'recommendation', 'message': 'Voici cinq choix', 'reservations': [], 'recommendations': choices}
        client = unittest.mock.Mock()
        client.response.side_effect = [{'output': calls}, {'output': [{'type': 'message', 'content': [{'type': 'output_text', 'text': json.dumps(result)}]}]}]
        job = {'prompt': 'Conseille-moi cinq lectures', 'scope': 'backlog', 'cancel': threading.Event(),
               'input_tokens': 0, 'output_tokens': 0, 'cost_usd': 0}
        completed = Advisor(self.store, None, client).run(job, lambda _: None)
        self.assertEqual(len(completed['recommendations']), 5)
        self.assertTrue(all(r['work']['sources'] and r['references'] for r in completed['recommendations']))


if __name__ == '__main__':
    unittest.main(verbosity=2)
