import json
import unittest
import tempfile
from pathlib import Path
from unittest.mock import Mock, patch
from chapter_pages import ChapterPage, has_identity, public_url
from reading_links import chapter_numbers, reading_links, web_chapters

WORK = '5ec0922a-4869-4e6b-a154-2307945cc406'
CHAPTER = '7c0cde37-9475-4b59-b385-fb4ff08c6ee2'
URL = 'https://reader.example/moonlight/chapter-41'


def page(title='Moonlight Chapter 41', body=None, url=URL):
    if body is None:
        body = '<div class="reading-content"><img src="https://cdn.example/41/1.jpg"><img src="https://cdn.example/41/2.jpg"></div>'
    return ChapterPage('<title>' + title + '</title><h1>' + title + '</h1>' + body, url)


def web_response(rows, cited=None):
    return {'output': [
        {'type': 'web_search_call', 'status': 'completed', 'action': {'sources': [{'url': value} for value in (cited if cited is not None else [row['url'] for row in rows])]}},
        {'type': 'message', 'content': [{'type': 'output_text', 'text': json.dumps(rows)}]},
    ]}


class ChapterPageTests(unittest.TestCase):
    def test_exact_title_number_and_actual_reader_are_required(self):
        self.assertEqual(page().availability(['Moonlight'], '41'), 'reader')
        for title in ['Moonlight Chapter 410', 'Moonlight Chapter 41.5', 'Other Story Chapter 41', 'Moonlight Volume 41', 'Moonlight - 41 chapters']:
            with self.subTest(title=title):
                self.assertIsNone(page(title).availability(['Moonlight'], '41'))

    def test_catalogue_with_chapter_count_or_list_is_not_a_reader(self):
        self.assertIsNone(page('Moonlight', '<p>41 chapters</p><a href="/chapter-41">Chapter 41</a>').availability(['Moonlight'], '41'))
        self.assertIsNone(page(body='<p>Chapter 41</p><img src="cover.jpg">').availability(['Moonlight'], '41'))
        self.assertIsNone(page(body='<div class="reading-content"><img src="cover.jpg"></div>').availability(['Moonlight'], '41'))

    def test_missing_pages_and_previews_are_rejected(self):
        self.assertIsNone(page(body='<p>Chapter not found</p>').availability(['Moonlight'], '41'))
        self.assertIsNone(page('Moonlight Chapter 41 preview').availability(['Moonlight'], '41'))
        self.assertIsNone(page(body='<div class="reading-content"></div>').availability(['Moonlight'], '41'))

    def test_chapter_sold_individually_is_accepted_but_unavailable_offers_are_not(self):
        for status in ['InStock', 'OutOfStock', 'PreOrder']:
            product = {'@type': 'Product', 'name': 'Moonlight Chapter 41', 'offers': {'availability': 'https://schema.org/' + status}}
            document = page(body='<script type="application/ld+json">' + json.dumps(product) + '</script>')
            self.assertEqual(document.availability(['Moonlight'], '41'), 'purchase' if status == 'InStock' else None)

    def test_native_chapter_labels_and_json_reader(self):
        self.assertTrue(has_identity('月の物語 第４１話', ['月の物語'], '41'))
        self.assertTrue(has_identity('月の物語(話売り) #41', ['月の物語'], '41'))
        self.assertFalse(has_identity('月の物語 41巻', ['月の物語'], '41'))
        document = page(body='<script>{"chapterImages":["https://cdn.example/page.webp"]}</script>')
        self.assertEqual(document.availability(['Moonlight'], '41'), 'reader')

    def test_public_page_fetch_rejects_local_destinations(self):
        for url in ['http://reader.example/41', 'https://user:password@reader.example/41', 'https://reader.example:8765/41']:
            with self.subTest(url=url), self.assertRaises(ValueError):
                public_url(url)
        with patch('chapter_pages.socket.getaddrinfo', return_value=[(2, 1, 6, '', ('127.0.0.1', 443))]), self.assertRaises(ValueError):
            public_url('https://reader.example/41')


class ReadingLinksTests(unittest.TestCase):
    def test_deep_link_from_a_searched_site_is_verified_instead_of_trusting_the_series(self):
        response = web_response([{'url': URL, 'chapter': '41', 'language': 'en'}], cited=['https://reader.example/series'])
        self.assertEqual(len(list(web_chapters(response, ['41'], ['Moonlight'], lambda url: page()))), 1)
        self.assertEqual(list(web_chapters(response, ['41'], ['Moonlight'], lambda url: page('Moonlight'))), [])

    def test_known_chapter_candidates_are_rechecked_not_blindly_returned_from_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Mock(cache=Path(directory))
            source.fetch.side_effect = lambda kind, url, **kwargs: {'data': [], 'total': 0} if '/chapter?' in url else {'data': {'attributes': {'title': {'en': 'Moonlight'}}}}
            first = reading_links(source, WORK, '41', lambda *args: web_response([{'url': URL, 'chapter': '41', 'language': 'en'}]), lambda url: page())
            self.assertEqual(len(first['chapters']), 1)
            second = reading_links(source, WORK, '41', lambda *args: web_response([]), lambda url: page())
            self.assertEqual(len(second['chapters']), 1)
            gone = reading_links(source, WORK, '41', lambda *args: web_response([]), lambda url: page(body='Chapter not found'))
            self.assertEqual(gone['chapters'], [])

    def test_web_citations_are_not_sufficient_without_page_verification(self):
        rows = [{'url': URL, 'chapter': '41', 'language': 'en'},
                {'url': 'https://reader.example/series', 'chapter': '', 'language': 'en', 'kind': 'independent_series'}]
        self.assertEqual(list(web_chapters(web_response(rows), ['41'], ['Moonlight'], lambda url: page(body='Only metadata'))), [])
        self.assertEqual(list(web_chapters(web_response(rows, cited=[]), ['41'], ['Moonlight'], lambda url: page())), [])
        confirmed = list(web_chapters(web_response(rows), ['41'], ['Moonlight'], lambda url: page()))
        self.assertEqual(len(confirmed), 1)
        self.assertTrue(confirmed[0]['verified'])

    def test_wrong_chapter_and_redirect_to_series_are_rejected(self):
        rows = [{'url': URL, 'chapter': '41', 'language': 'en'}]
        for document in [page('Moonlight Chapter 40'), page('Moonlight', url='https://reader.example/series')]:
            self.assertEqual(list(web_chapters(web_response(rows), ['41'], ['Moonlight'], lambda url: document)), [])

    def test_one_page_does_not_confirm_every_number_of_a_range(self):
        rows = [{'url': URL, 'chapter': number, 'language': 'en'} for number in ['41', '42']]
        loader = Mock(return_value=page())
        confirmed = list(web_chapters(web_response(rows), ['41', '42'], ['Moonlight'], loader))
        self.assertEqual([row['chapter'] for row in confirmed], ['41'])
        loader.assert_called_once_with(URL)

    def test_one_pool_excludes_generic_platforms_and_empty_mangadex_chapters(self):
        source = Mock()
        source.fetch.side_effect = [
            {'data': {'attributes': {'title': {'en': 'Moonlight'}, 'links': {'raw': 'https://publisher.example/series', 'al': '123'}}}},
            {'data': [
                {'id': CHAPTER, 'attributes': {'chapter': '41', 'pages': 20, 'translatedLanguage': 'fr'}},
                {'id': CHAPTER, 'attributes': {'chapter': '42', 'pages': 0, 'translatedLanguage': 'en'}},
                {'id': CHAPTER, 'attributes': {'chapter': '42', 'pages': 0, 'translatedLanguage': 'ja', 'externalUrl': 'https://publisher.example/series'}},
            ], 'total': 3},
        ]
        web = Mock(return_value=web_response([{'url': URL, 'chapter': '41', 'language': 'en'}]))
        def loader(url):
            return page() if url == URL else page('Moonlight', url=url)
        result = reading_links(source, WORK, '41-42', web, loader)
        self.assertEqual({row['site'] for row in result['chapters']}, {'MangaDex', 'reader.example'})
        self.assertEqual(result['missing'], ['42'])
        self.assertNotIn('official', result)
        self.assertNotIn('independent', result)
        self.assertEqual(source.fetch.call_count, 2)
        web.assert_called_once_with(['Moonlight'], ['41', '42'], ['https://publisher.example/series'])

    def test_chapter_ranges_are_bounded_and_decimals_preserved(self):
        self.assertEqual(chapter_numbers('12,5'), ['12.5'])
        self.assertEqual(chapter_numbers('12-14'), ['12', '13', '14'])
        for query in ['', '30-1', '1-26', '-1', 'chapitre 41']:
            with self.subTest(query=query), self.assertRaises(ValueError):
                chapter_numbers(query)
