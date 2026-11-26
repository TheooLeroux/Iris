"""Recherche de liens de lecture, indépendante du moteur de conseil."""
import json
import re
import hashlib
import time
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
from decimal import Decimal
from urllib.parse import urlencode, urlsplit, urldefrag
from uuid import UUID
from storage import norm
from chapter_pages import fetch_chapter_page

BASE = 'https://api.mangadex.org'
RATINGS = [('contentRating[]', rating) for rating in ('safe', 'suggestive', 'erotica', 'pornographic')]


def chapter_numbers(value):
    value = value.strip().replace(',', '.')
    if re.fullmatch(r'[0-9]{1,5}(?:\.[0-9]{1,3})?', value):
        number = Decimal(value)
        return [format(number.normalize(), 'f')]
    match = re.fullmatch(r'([0-9]{1,5})\s*[-–]\s*([0-9]{1,5})', value)
    if match:
        start, end = map(int, match.groups())
        if 0 <= end - start < 25:
            return [str(n) for n in range(start, end + 1)]
    raise ValueError('Saisis un chapitre (12 ou 12.5) ou une plage de 25 chapitres maximum (12-20).')


def search(catalogues, title):
    if not 2 <= len(title.strip()) <= 200:
        raise ValueError('Saisis un titre de 2 à 200 caractères.')
    params = [('title', title.strip()), ('limit', 12), ('order[relevance]', 'desc'),
              ('includes[]', 'author'), *RATINGS]
    rows = catalogues.fetch('mangadex', BASE + '/manga?' + urlencode(params), ttl=900)
    works = []
    requested_title = norm(title)
    for row in rows['data']:
        attrs = row['attributes']
        titles = attrs['title']
        aliases = [t for a in attrs.get('altTitles', []) for t in a.values()]
        original_title = next(iter(titles.values()), row['id'])
        title = next((alias for alias in [*titles.values(), *aliases] if norm(alias) == requested_title),
                     titles.get('en') or original_title)
        authors = [(rel.get('attributes') or {}).get('name') for rel in row.get('relationships', []) if rel['type'] == 'author']
        alternate = next((a for a in [original_title, *aliases] if norm(a) != norm(title)), None)
        subtitle = ' · '.join(str(x) for x in [attrs.get('year'), *authors, alternate] if x)
        works.append({'id': row['id'], 'title': title, 'subtitle': subtitle})
    works.sort(key=lambda item: norm(item['title']) != requested_title)
    return {'works': works}


def https_url(value):
    if not isinstance(value, str):
        return None
    try:
        parsed = urlsplit(value)
        if parsed.scheme == 'https' and parsed.hostname and parsed.username is None and parsed.password is None:
            return value
    except ValueError:
        pass
    return None


def verified_pages(candidates, titles, page_loader=fetch_chapter_page):
    candidates = candidates[:16]
    urls = list(dict.fromkeys(row['url'] for row in candidates))[:12]
    with ThreadPoolExecutor(max_workers=4) as pool:
        pending = {url: pool.submit(page_loader, url) for url in urls}
        for row in candidates:
            if row['url'] not in pending:
                continue
            try:
                page = pending[row['url']].result()
                access = page.availability(titles, row['chapter'])
                if access:
                    yield {**row, 'url': page.url, 'site': urlsplit(page.url).hostname,
                           'access': access, 'verified': True}
            except (OSError, ValueError, KeyError, TypeError, UnicodeError):
                continue


def web_chapters(response, numbers, titles, page_loader=fetch_chapter_page):
    output = response.get('output', [])
    sources = {item.get('url') for call in output if call.get('type') == 'web_search_call'
               for item in call.get('action', {}).get('sources', [])}
    parts = [part for call in output if call.get('type') == 'message' for part in call.get('content', [])
             if part.get('type') == 'output_text']
    sources.update(annotation.get('url') for part in parts for annotation in part.get('annotations', [])
                   if annotation.get('type') == 'url_citation')
    source_hosts = {urlsplit(url).hostname for url in sources if isinstance(url, str)}
    if not any(call.get('type') == 'web_search_call' and call.get('status') == 'completed' for call in output):
        raise ValueError('Recherche Web incomplète.')
    raw = ''.join(part['text'] for part in parts).strip()
    if raw.startswith('```'):
        raw = re.sub(r'^\x60{3}(?:json)?\s*|\s*\x60{3}$', '', raw)
    rows = json.loads(raw)
    if not isinstance(rows, list):
        raise ValueError('Réponse Web invalide.')
    candidates = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        url = https_url(row.get('url'))
        if not url or urlsplit(url).hostname not in source_hosts or row.get('kind') not in (None, 'official', 'independent'):
            continue
        try:
            parsed = chapter_numbers(str(row.get('chapter', '')))
        except ValueError:
            continue
        if len(parsed) != 1 or parsed[0] not in numbers:
            continue
        language = row.get('language')
        if not isinstance(language, str) or not re.fullmatch(r'[a-z]{2,3}(?:-[a-z]{2,4})?', language.lower()):
            language = '?'
        candidates.append({'url': url, 'chapter': parsed[0], 'language': language.lower()})
    yield from verified_pages(candidates, titles, page_loader)


def reading_links(catalogues, work_id, chapters, web_search=None, page_loader=fetch_chapter_page):
    work_id = str(UUID(work_id))
    numbers = chapter_numbers(chapters)
    work = catalogues.fetch('mangadex', BASE + '/manga/' + work_id, ttl=900)['data']
    attrs = work['attributes']
    titles = list(dict.fromkeys([*attrs['title'].values(),
                                *(title for alt in attrs.get('altTitles', []) for title in alt.values())]))
    warnings, external = [], []
    cache_root = getattr(catalogues, 'cache', None)
    cache_file = cache_root / ('reading-candidates-' + hashlib.sha256(work_id.encode()).hexdigest() + '.json') if isinstance(cache_root, Path) else None
    previous = []
    if cache_file and cache_file.exists() and time.time() - cache_file.stat().st_mtime < 7 * 86400:
        try:
            previous = json.loads(cache_file.read_text(encoding='utf-8'))
            if not isinstance(previous, list):
                previous = []
        except (OSError, ValueError):
            previous = []
    external.extend(row for row in previous if isinstance(row, dict) and row.get('chapter') in numbers and https_url(row.get('url')))
    params = [('manga', work_id), ('limit', 100), ('includes[]', 'scanlation_group'), *RATINGS]
    params.extend(('chapter[]', n) for n in numbers)
    results = {}

    def remember(row):
        key = (row['language'], row['chapter'], urldefrag(row['url'])[0].rstrip('/'))
        results.setdefault(key, row)

    for offset in range(0, 500, 100):
        try:
            response = catalogues.fetch('mangadex', BASE + '/chapter?' + urlencode([*params, ('offset', offset)]), ttl=60)
        except (OSError, ValueError, KeyError):
            warnings.append('Une source de chapitres n’a pas pu être consultée.')
            break
        for row in response['data']:
            chapter = row['attributes']
            number = chapter.get('chapter')
            if not isinstance(number, str) or not re.fullmatch(r'[0-9]+(?:\.[0-9]+)?', number):
                continue
            number = format(Decimal(number).normalize(), 'f')
            if number not in numbers or chapter.get('isUnavailable'):
                continue
            manga_ids = [rel.get('id') for rel in row.get('relationships', []) if rel.get('type') == 'manga']
            if manga_ids and work_id not in manga_ids:
                continue
            language = chapter.get('translatedLanguage') or '?'
            url = https_url(chapter.get('externalUrl'))
            if chapter.get('externalUrl'):
                if url:
                    external.append({'url': url, 'chapter': number, 'language': language})
                continue
            if not isinstance(chapter.get('pages'), int) or chapter['pages'] <= 0:
                continue
            try:
                chapter_id = str(UUID(row['id']))
            except (ValueError, TypeError):
                continue
            remember({'url': 'https://mangadex.org/chapter/' + chapter_id, 'chapter': number,
                      'language': language, 'site': 'MangaDex', 'access': 'reader', 'verified': True})
        if offset + 100 >= response['total'] or not response['data']:
            break
    else:
        warnings.append('La recherche atteint sa limite de versions consultables. Essaie une plage plus courte.')
    for row in verified_pages(external, titles, page_loader):
        remember(row)
    if web_search:
        links = attrs.get('links') or {}
        starting_urls = [url for name in ('raw', 'engtl') if (url := https_url(links.get(name)))]
        try:
            for row in web_chapters(web_search(titles[:24], numbers, starting_urls), numbers, titles, page_loader):
                remember(row)
        except (OSError, ValueError, KeyError, TypeError):
            warnings.append('La recherche complémentaire n’a pas abouti. Les liens déjà confirmés restent disponibles.')
    found = sorted(results.values(), key=lambda row: (row['language'], Decimal(row['chapter']), row['site']))
    if cache_file:
        # Only candidate URLs are retained; every cached link is rechecked next time.
        saved = {row['url']: row for row in previous if isinstance(row, dict) and https_url(row.get('url'))}
        saved.update({row['url']: {key: row[key] for key in ('url', 'chapter', 'language')}
                      for row in found if urlsplit(row['url']).hostname != 'mangadex.org'})
        try:
            cache_file.write_text(json.dumps(list(saved.values())[-200:], ensure_ascii=False), encoding='utf-8')
        except OSError:
            pass
    missing = [number for number in numbers if not any(row['chapter'] == number for row in found)]
    return {'requested': numbers, 'chapters': found, 'missing': missing, 'warnings': list(dict.fromkeys(warnings))}
