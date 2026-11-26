"""Adaptateurs bornés aux API publiques, cache local et limitation de débit."""
import hashlib
import json
import re
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from storage import RUNTIME, canonical, norm, narrative_quality

FIELDS = '''id title{romaji english native} synonyms countryOfOrigin status chapters genres
tags{name rank isMediaSpoiler isGeneralSpoiler} description(asHtml:false) siteUrl
staff(perPage:8){edges{node{name{full}}}}'''


class Catalogues:
    def __init__(self, store=None, runtime=RUNTIME):
        self.store = store
        self.cache = runtime / 'catalogue-cache'
        self.cache.mkdir(parents=True, exist_ok=True)
        self.locks = {s: threading.Lock() for s in ('anilist', 'mangadex', 'mangaupdates')}
        self.last = {s: 0 for s in self.locks}

    @staticmethod
    def same_identity(left, right):
        def aliases(work):
            return {norm(work['title'])} | {norm(a) for s in work['sources'] for a in s['aliases'] if norm(a)}
        def authors(work):
            return {''.join(sorted(re.findall(r'\w+', name.casefold()))) for s in work['sources'] for name in s['creators'] if name}
        return bool(aliases(left) & aliases(right) and authors(left) & authors(right))

    def enrich(self, candidate_id, reason, cancel=None):
        """Cherche les alias dans les catalogues complémentaires, avec contrôle d'identité."""
        work = self.store.get(candidate_id)
        if not work:
            raise ValueError('Œuvre inconnue.')
        titles = list(dict.fromkeys([work['title']] + [a for s in work['sources'] for a in s['aliases'] if a]))
        # Une variante latine et une variante native : ne pas rester prisonnier d'un seul titre.
        native = next((a for a in titles[1:] if any(ord(c) > 0x3000 for c in a)), None)
        alternative = next((a for a in titles[1:] if norm(a) != norm(titles[0])), None)
        queries = list(dict.fromkeys([titles[0]] + ([native or alternative] if native or alternative else [])))
        existing = {s['catalogue'] for s in work['sources']}
        targets = [s for s in ('mangaupdates', 'anilist', 'mangadex') if s not in existing]
        if not targets:
            targets = ['mangaupdates', 'anilist']
        attempts, confirmed, unconfirmed = [], [], []
        for source in targets:
            matched = False
            for title in queries:
                if cancel is not None and cancel.is_set():
                    raise InterruptedError('Enrichissement annulé.')
                try:
                    found = self.search(source, title, [], [], '', False, 2)
                    if isinstance(found, dict):
                        attempts.append({'source': source, 'title': title, 'error': found.get('error', 'Recherche échouée')})
                        continue
                    attempts.append({'source': source, 'title': title, 'results': len(found)})
                    for other in found:
                        if other['id'] == work['id'] or self.same_identity(work, other):
                            self.store.attach_verified_sources(work, other)
                            confirmed.extend(s['id'] for s in other['sources'])
                            matched = True
                        else:
                            unconfirmed.append({'id': other['id'], 'title': other['title'], 'reason': 'Identité non confirmée : titre et créateur doivent correspondre.'})
                    if matched:
                        break
                except Exception as error:
                    attempts.append({'source': source, 'title': title, 'error': str(error)[:350]})
        return {'candidate_id': candidate_id, 'reason': reason, 'attempts': attempts,
                'confirmed_sources': list(dict.fromkeys(confirmed)), 'unconfirmed_matches': unconfirmed[:6],
                'quality': narrative_quality(work), 'work': self.store.card(work, full=True),
                'note': 'Pas de résultat ne prouve pas l’absence de l’œuvre. Les tags et titres seuls ne décrivent pas tout un univers.'}

    def fetch(self, source, url, payload=None, ttl=86400):
        key = hashlib.sha256(json.dumps([url, payload], sort_keys=True).encode()).hexdigest()
        file = self.cache / (source + '-' + key + '.json')
        if file.exists() and time.time() - file.stat().st_mtime < ttl:
            return json.loads(file.read_text(encoding='utf-8'))
        with self.locks[source]:
            interval = {'anilist': 2.2, 'mangadex': 0.7, 'mangaupdates': 1.3}[source]
            time.sleep(max(0, interval - (time.monotonic() - self.last[source])))
            for attempt in range(2):
                self.last[source] = time.monotonic()
                request = urllib.request.Request(url, data=json.dumps(payload).encode() if payload is not None else None,
                    headers={'Content-Type': 'application/json', 'User-Agent': 'RecoLecture-personal-prototype/0.1'})
                try:
                    with urllib.request.urlopen(request, timeout=25) as response:
                        data = json.load(response)
                    if isinstance(data, dict) and data.get('errors'):
                        raise ValueError('Erreur GraphQL : ' + str(data['errors'])[:500])
                    file.write_text(json.dumps(data, ensure_ascii=False), encoding='utf-8')
                    return data
                except urllib.error.HTTPError as error:
                    if error.code in (429, 500, 502, 503, 504) and attempt == 0:
                        retry = error.headers.get('Retry-After', '8')
                        time.sleep(min(20, int(retry) if retry.isdigit() else 8))
                        continue
                    raise ValueError(f'{source} indisponible (HTTP {error.code}).') from None

    def taxonomy(self, source):
        if source == 'anilist':
            data = self.fetch(source, 'https://graphql.anilist.co', {'query': '{GenreCollection MediaTagCollection{name category}}'}, 604800)['data']
            return {'genres': data['GenreCollection'], 'tags': [x['name'] for x in data['MediaTagCollection']]}
        if source == 'mangadex':
            data = self.fetch(source, 'https://api.mangadex.org/manga/tag', ttl=604800)
            return {'tags': {x['attributes']['name']['en']: x['id'] for x in data['data']}}
        return {'information': 'MangaUpdates : recherche par titre uniquement, puis genres et catégories des fiches.'}

    def cover_url(self, source_id):
        """Retrouve la jaquette de l'identifiant exact, avec le cache des catalogues."""
        catalog, _, key = source_id.partition(':')
        if catalog == 'mangaupdates' and re.fullmatch(r'[0-9]+', key):
            row = self.fetch(catalog, 'https://api.mangaupdates.com/v1/series/' + key)
            if str(row.get('series_id')) == key:
                urls = (row.get('image') or {}).get('url') or {}
                return urls.get('original') or urls.get('thumb')
        elif catalog == 'anilist' and re.fullmatch(r'[0-9]+', key):
            payload = {'query': 'query($id:Int!){Media(id:$id,type:MANGA){id coverImage{large medium}}}',
                       'variables': {'id': int(key)}}
            row = self.fetch(catalog, 'https://graphql.anilist.co', payload)['data'].get('Media') or {}
            if str(row.get('id')) == key:
                image = row.get('coverImage') or {}
                return image.get('large') or image.get('medium')
        elif catalog == 'mangadex' and re.fullmatch(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}', key):
            row = self.fetch(catalog, 'https://api.mangadex.org/manga/' + key + '?includes%5B%5D=cover_art')['data']
            if row.get('id') == key:
                for relation in row.get('relationships', []):
                    name = (relation.get('attributes') or {}).get('fileName', '')
                    if relation.get('type') == 'cover_art' and re.fullmatch(r'[\w.-]+\.(?:jpg|jpeg|png|webp)', name, re.I):
                        return f'https://uploads.mangadex.org/covers/{key}/{name}.256.jpg'
        return None

    def search(self, source, title, tags, excluded_tags, country, finished, limit=6):
        limit = max(1, min(8, int(limit)))
        if len(tags) > 5 or len(excluded_tags) > 5:
            return {'error': 'Cinq thèmes inclus et cinq exclus maximum par recherche.'}
        if source == 'anilist':
            taxonomy = self.taxonomy(source)
            genre_names = set(taxonomy['genres'])
            allowed = set(taxonomy['tags']) | genre_names
            if any(t not in allowed for t in tags + excluded_tags):
                return {'error': 'Thème AniList inconnu : consulter taxonomy.',
                        'unknown': [t for t in tags + excluded_tags if t not in allowed], 'genres': taxonomy['genres']}
            genres = [t for t in tags if t in genre_names]
            excluded_genres = [t for t in excluded_tags if t in genre_names]
            tags = [t for t in tags if t not in genre_names]
            excluded_tags = [t for t in excluded_tags if t not in genre_names]
            args = ['type:MANGA', 'format_in:[MANGA,ONE_SHOT]', 'sort:[POPULARITY_DESC]']
            variables, declarations = {}, []
            for name, value, kind, argument in [('q', title, 'String', 'search'), ('tags', tags, '[String]', 'tag_in'),
                ('excluded', excluded_tags, '[String]', 'tag_not_in'), ('genres', genres, '[String]', 'genre_in'),
                ('excluded_genres', excluded_genres, '[String]', 'genre_not_in'), ('country', country, 'CountryCode', 'countryOfOrigin')]:
                if value:
                    declarations.append('$' + name + ':' + kind)
                    args.append(argument + ':$' + name)
                    variables[name] = value
            if finished:
                args.append('status:FINISHED')
            declaration = '(' + ','.join(declarations) + ')' if declarations else ''
            query = 'query' + declaration + '{Page(perPage:' + str(limit) + '){media(' + ','.join(args) + '){' + FIELDS + '}}}'
            rows = self.fetch(source, 'https://graphql.anilist.co', {'query': query, 'variables': variables})['data']['Page']['media']
            records = [self.anilist(x) for x in rows]
        elif source == 'mangadex':
            taxonomy = self.taxonomy(source)['tags']
            if any(t not in taxonomy for t in tags + excluded_tags):
                return {'error': 'Thème MangaDex inconnu : consulter taxonomy.'}
            params = [('limit', limit), ('includes[]', 'author'), ('includes[]', 'artist')]
            params += [('contentRating[]', x) for x in ('safe', 'suggestive', 'erotica', 'pornographic')]
            if title:
                params += [('title', title), ('order[relevance]', 'desc')]
            else:
                params.append(('order[followedCount]', 'desc'))
            params += [('includedTags[]', taxonomy[t]) for t in tags]
            params += [('excludedTags[]', taxonomy[t]) for t in excluded_tags]
            if country:
                lang = {'KR': 'ko', 'JP': 'ja', 'CN': 'zh'}.get(country)
                if not lang:
                    return {'error': 'Pays MangaDex pris en charge : KR, JP, CN.'}
                params.append(('originalLanguage[]', lang))
            if finished:
                params.append(('status[]', 'completed'))
            rows = self.fetch(source, 'https://api.mangadex.org/manga?' + urllib.parse.urlencode(params))['data']
            records = [self.mangadex(x) for x in rows]
        elif source == 'mangaupdates':
            if not title.strip() or tags or excluded_tags or country or finished:
                return {'error': 'MangaUpdates : renseigner seulement un titre ; aucun filtre ici.'}
            data = self.fetch(source, 'https://api.mangaupdates.com/v1/series/search', {'search': title, 'perpage': min(limit, 3)})
            records = []
            for entry in data.get('results', [])[:3]:
                row = entry['record']
                if row.get('type') in ('Novel', 'Artbook'):
                    continue
                detail = self.fetch(source, 'https://api.mangaupdates.com/v1/series/' + str(row['series_id']))
                records.append(self.mangaupdates(detail))
        else:
            return {'error': 'Catalogue inconnu.'}
        return [self.store.register(canonical(source, x)) for x in records]

    @staticmethod
    def anilist(row):
        return {'id': row['id'], 'chapters':row.get('chapters'), 'title': row['title'], 'aliases': list(row['title'].values()) + row.get('synonyms', []),
                'url': row['siteUrl'], 'country': row.get('countryOfOrigin'), 'status': row.get('status'),
                'tags': row.get('tags', []), 'genres': row.get('genres', []), 'synopsis': row.get('description'),
                'creators': [x['node']['name']['full'] for x in row.get('staff', {}).get('edges', [])]}

    @staticmethod
    def mangadex(row):
        a = row['attributes']
        return {'id': row['id'], 'title': a['title'],
                'aliases': list(a['title'].values()) + [v for x in a.get('altTitles', []) for v in x.values()],
                'url': 'https://mangadex.org/title/' + row['id'], 'language': a.get('originalLanguage'),
                'status': a.get('status'), 'synopsis_en': a.get('description', {}).get('en'),
                'synopsis_fr': a.get('description', {}).get('fr'),
                'tags': [{'name': x['attributes']['name']['en']} for x in a.get('tags', [])],
                'creators': [x.get('attributes', {}).get('name') for x in row.get('relationships', []) if x['type'] in ('author', 'artist')]}

    @staticmethod
    def mangaupdates(row):
        return {'id': row['series_id'], 'title': row['title'], 'url': row['url'],
                'aliases': [row['title']] + [x['title'] for x in row.get('associated', [])],
                'type': row.get('type'), 'completed': row.get('completed'), 'status': row.get('status'),
                'genres': [x['genre'] for x in row.get('genres', [])],
                'tags': [{'category': x['category']} for x in row.get('categories', [])],
                'synopsis': row.get('description'), 'creators': [x['name'] for x in row.get('authors', [])]}
