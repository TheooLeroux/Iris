"""Données locales, identités revues et preuves consultables. Aucune clé stockée."""
import hashlib
from contextlib import contextmanager
import html
import json
import re
import sqlite3
import threading
import unicodedata
from pathlib import Path
from advice_filters import GENRES, validate_filters

ROOT = Path(__file__).resolve().parent
PROJECT = ROOT.parent
RUNTIME = ROOT / 'runtime'


def norm(value):
    value = unicodedata.normalize('NFKD', value or '').casefold().replace('&', 'and').replace('×', 'x')
    return ''.join(c for c in value if c.isalnum())


def clean(value):
    return html.unescape(re.sub(r'<[^>]+>', ' ', str(value or ''))).strip()


def narrative_quality(work):
    sources = work['sources']
    described = [s['id'] for s in sources if s['fields'].get('synopsis', '').strip()]
    longest = max((len(s['fields'].get('synopsis', '').strip()) for s in sources), default=0)
    return {'has_synopsis': bool(described), 'narrative_sources': described,
            'needs_enrichment': longest < 160,
            'note': 'Un synopsis peut encore être insuffisant pour le décor précis : vérifier les passages pertinents.'}


def canonical(source, row):
    """Même représentation pour l'audit et les réponses fraîches des catalogues."""
    titles = row.get('title')
    if isinstance(titles, dict):
        title = titles.get('english') or titles.get('en') or titles.get('romaji') or next((v for v in titles.values() if v), '?')
    else:
        title = titles or '?'
    tags = [x.get('name') or x.get('category') for x in row.get('tags', [])]
    genres = row.get('genres', [])
    country = row.get('country') or {'ko': 'KR', 'ja': 'JP', 'zh': 'CN', 'en': 'EN'}.get(row.get('language'))
    if source == 'mangaupdates':
        country = {'Manhwa': 'KR', 'Manga': 'JP', 'Manhua': 'CN'}.get(row.get('type'))
    status = str(row.get('status') or '').upper()
    if source == 'mangaupdates':
        # completed est un booléen dans l'API ; le texte "status" reste disponible.
        complete = row.get('completed')
        status = 'FINISHED' if complete is True else 'UNKNOWN'
    status = {'COMPLETED': 'FINISHED', 'ONGOING': 'RELEASING', 'CANCELLED': 'CANCELLED'}.get(status, status)
    if status not in ('FINISHED', 'RELEASING', 'HIATUS', 'CANCELLED'):
        status = 'UNKNOWN'
    aliases = list(dict.fromkeys([title] + [str(x) for x in row.get('aliases', []) if x]))
    sid = source + ':' + str(row['id'])
    fields = {
        'title': title,
        'aliases': ' | '.join(aliases),
        'synopsis': clean(row.get('synopsis_fr') or row.get('synopsis_en') or row.get('synopsis'))[:7000],
        'tags': ' | '.join(x for x in tags if x),
        'genres': ' | '.join(genres),
        'country': country or 'UNKNOWN',
        'status': status,
        'creators': ' | '.join(x for x in row.get('creators', []) if x),
        'publication_details': clean(row.get('status')),
        'chapters': str(row.get('chapters') or ''),
    }
    return {'id': sid, 'catalogue': source, 'catalogue_id': str(row['id']), 'title': title,
            'url': row.get('url', ''), 'fields': fields, 'aliases': aliases,
            'creators': [x for x in row.get('creators', []) if x], 'tags': [x for x in tags if x],
            'genres': genres, 'country': country, 'status': status}


class Store:
    def __init__(self, runtime=RUNTIME, library=None, filters=(), data_root=PROJECT):
        validate_filters(filters)
        self.filters = set(filters)
        self.recommended = set()
        self.recommended_names = {}
        self.runtime = Path(runtime)
        self.runtime.mkdir(parents=True, exist_ok=True)
        self.db = self.runtime / 'recolecture.sqlite3'
        self.lock = threading.RLock()
        with self.connect() as db:
            db.executescript('''
            CREATE TABLE IF NOT EXISTS runs(id TEXT PRIMARY KEY, created TEXT DEFAULT CURRENT_TIMESTAMP, prompt TEXT, scope TEXT, data TEXT);
            CREATE TABLE IF NOT EXISTS feedback(id INTEGER PRIMARY KEY, created TEXT DEFAULT CURRENT_TIMESTAMP, run_id TEXT, candidate_id TEXT, kind TEXT, comment TEXT, identity TEXT);
            CREATE TABLE IF NOT EXISTS discovered(id TEXT PRIMARY KEY, data TEXT);
            ''')
        self.works = {}
        self.source_index = {}
        self.alias_index = {}
        data_root = Path(data_root)
        self.library = library if library is not None else json.loads((data_root / 'mangatime-20261119-134639-04c64935.json').read_text(encoding='utf-8'))
        audit = json.loads((data_root / 'recherche-catalogues/audit-complet/resultats-revus.json').read_text(encoding='utf-8'))
        self.audit_date = audit['date']
        for item in self.library:
            wid = 'lib:' + hashlib.sha256(item['titre'].encode()).hexdigest()[:14]
            work = {'id': wid, 'title': item['titre'], 'library': item, 'sources': [], 'identity': 'audit_revu'}
            self.works[wid] = work
            for name, entries in audit['sources'].items():
                entry = entries.get(item['titre'], {})
                if entry.get('state') == 'matched':
                    work['sources'].append(canonical(name, entry['selected']))
            if item['titre'] == 'Vowrune - GL':
                extra = json.loads((data_root / 'recherche-catalogues/vowrune-identification.json').read_text(encoding='utf-8'))
                for n, source in enumerate(extra['sources']):
                    work['sources'].append(canonical('publication', {
                        'id': 'vowrune-' + str(n), 'title': source['title'], 'aliases': extra['verified_title_variants'],
                        'url': source['url'], 'genres': source['genres'], 'creators': [extra['creator']],
                        'status': source.get('publication_status', ''), 'synopsis': extra['synopsis_paraphrase_fr']}))
            self._index(work)
        with self.connect() as db:
            for previous in db.execute('SELECT data FROM runs'):
                self.remember(json.loads(previous[0]))
            saved = db.execute('SELECT data FROM discovered').fetchall()
        for row in saved:
            work = json.loads(row['data'])
            if any(self.works[k]['library'] for s in work['sources'] for a in s['aliases'] for k in self.alias_index.get(norm(a), ())):
                work['possible_library_overlap'] = True
            if any(self.works[self.source_index[s['id']]]['library'] for s in work['sources'] if s['id'] in self.source_index):
                work['possible_library_overlap'] = True
            # Conserver les anciens identifiants utilisés dans les essais et retours.
            self.works[work['id']] = work
            self._index(work)

    @contextmanager
    def connect(self):
        connection = sqlite3.connect(self.db, timeout=15)
        connection.row_factory = sqlite3.Row
        try:
            with connection:
                yield connection
        finally:
            connection.close()

    def _index(self, work):
        for source in work['sources']:
            previous = self.works.get(self.source_index.get(source['id']))
            if not previous or not previous['library'] or work['library']:
                self.source_index[source['id']] = work['id']
        aliases = [work['title']] + [a for s in work['sources'] for a in s['aliases']]
        for alias in aliases:
            if norm(alias):
                self.alias_index.setdefault(norm(alias), set()).add(work['id'])

    def register(self, source):
        with self.lock:
            if source['id'] in self.source_index:
                work = self.works[self.source_index[source['id']]]
                previous = next(s for s in work['sources'] if s['id'] == source['id'])
                previous['fields'].update({k: v for k, v in source['fields'].items() if v and v != 'UNKNOWN'})
                for key in ('aliases', 'creators', 'tags', 'genres'):
                    previous[key] = list(dict.fromkeys(previous.get(key, []) + source.get(key, [])))
                self._index(work)
                self.persist_work(work)
                return work
            overlapping = set()
            for alias in source['aliases']:
                overlapping.update(self.alias_index.get(norm(alias), set()))
            creators = {norm(x) for x in source['creators']}
            verified = [self.works[k] for k in overlapping if creators & {
                norm(c) for s in self.works[k]['sources'] for c in s['creators']}]
            if len(verified) == 1:
                work = verified[0]
                work['sources'].append(source)
            else:
                work = {'id': source['id'], 'title': source['title'], 'library': None,
                        'sources': [source], 'identity': 'fiche_catalogue',
                        'possible_library_overlap': any(self.works[k]['library'] for k in overlapping)}
                self.works[work['id']] = work
            self._index(work)
            if not work['library']:
                with self.connect() as db:
                    db.execute('INSERT OR REPLACE INTO discovered(id,data) VALUES(?,?)',
                               (work['id'], json.dumps(work, ensure_ascii=False)))
            return work

    def persist_work(self, work):
        if not work['library']:
            with self.connect() as db:
                db.execute('INSERT OR REPLACE INTO discovered(id,data) VALUES(?,?)',
                           (work['id'], json.dumps(work, ensure_ascii=False)))

    def attach_verified_sources(self, work, other):
        """Appelé après vérification titre ET créateur, jamais sur un lien seul."""
        with self.lock:
            if other['library'] and not work['library']:
                work['possible_library_overlap'] = True
            known = {s['id'] for s in work['sources']}
            work['sources'].extend(s for s in other['sources'] if s['id'] not in known)
            self._index(work)
            self.persist_work(work)

    def get(self, wid):
        with self.lock:
            return self.works.get(wid)

    def candidates(self, query, scope, limit=12):
        """Rechercher aussi les œuvres publiques déjà découvertes, pas seulement la pile."""
        q = norm(query)
        works = [w for w in list(self.works.values()) if self.eligibility(w, scope)[0]
                 and (not q or q in norm(json.dumps(self.card(w, full=True), ensure_ascii=False)))]
        works.sort(key=lambda w: (bool(q and q in norm(w['title'])), narrative_quality(w)['has_synopsis']), reverse=True)
        seen, result = set(), []
        for work in works:
            sources = {s['id'] for s in work['sources']}
            if sources & seen:
                continue
            seen.update(sources)
            result.append(self.card(work))
            if len(result) >= limit:
                break
        return result

    def feedback(self, already_read=False):
        with self.connect() as db:
            query = '''SELECT f.*, r.prompt AS request_prompt, r.scope AS request_scope
                       FROM feedback f LEFT JOIN runs r ON r.id=f.run_id'''
            query += " WHERE f.kind='already_read' ORDER BY f.id DESC" if already_read else ' ORDER BY f.id DESC LIMIT 100'
            return [dict(x) for x in db.execute(query)]

    def remember(self, run):
        result = run.get('result') or {}
        if run.get('status') != 'done' or result.get('status') != 'recommendation':
            return
        for choice in result.get('recommendations', [result]):
            work = choice.get('work') or {}
            self.recommended.add(choice.get('candidate_id'))
            names = {norm(work.get('title'))}
            authors = set()
            for source in work.get('sources', []):
                self.recommended.add(source['id'])
                names.update(norm(a) for a in source['fields'].get('aliases', '').split(' | ') if a)
                authors.update(norm(a) for a in source['fields'].get('creators', '').split(' | ') if a)
            for name in names - {''}:
                self.recommended_names.setdefault(name, []).append(authors)

    def eligibility(self, work, scope):
        sources = work['sources']
        names = {norm(work['title'])} | {norm(a) for s in sources for a in s['aliases']}
        if work['id'] in self.recommended or any(s['id'] in self.recommended for s in sources) :
            return False, 'Déjà recommandé dans un conseil précédent.'
        authors = {norm(a) for s in sources for a in s['creators']}
        if any(not authors or not old or authors & old for n in names for old in self.recommended_names.get(n, [])):
            return False, 'Déjà recommandé sous ce titre ou un alias.'
        item = work.get('library') or {}
        statuses = {s['status'] for s in sources} - {'UNKNOWN', ''}
        publication = {'Terminé':'FINISHED', 'En cours':'RELEASING', 'En pause':'HIATUS'}.get(item.get('statut_publication'))
        if publication:
            statuses.add(publication)
        if 'finished' in self.filters and statuses != {'FINISHED'}:
            return False, 'Publication terminée non confirmée.'
        if 'ongoing' in self.filters and statuses != {'RELEASING'}:
            return False, 'Publication en cours non confirmée.'
        counts = [item.get('chapitres_total')] + [s['fields'].get('chapters') for s in sources]
        known = [int(str(n)) for n in counts if str(n).isascii() and str(n).isdigit() and int(n) > 0]
        if 'long' in self.filters and (not known or min(known) <= 50):
            return False, 'Plus de 50 chapitres non confirmés.'
        if 'short' in self.filters and (not known or max(known) > 50):
            return False, 'De 1 à 50 chapitres non confirmés.'
        if 'very_long' in self.filters and (not known or min(known) <= 100):
            return False, 'Plus de 100 chapitres non confirmés.'
        countries = {s['country'] for s in sources} - {None, '', 'UNKNOWN'}
        for value in self.filters:
            if value.startswith('country:') and countries != {value.split(':')[1]}:
                return False, 'Origine demandée non confirmée.'
        genres = {norm(label) for s in sources for label in s['genres'] + s['tags']}
        for value in self.filters:
            if value.startswith('genre:') and not genres.intersection(
                    norm(label) for label in GENRES[value.split(':')[1]]):
                return False, 'Genre demandé non confirmé : ' + GENRES[value.split(':')[1]][0] + '.'

        known_ids = {s['id'] for s in work['sources']}
        known_aliases = {norm(a) for s in work['sources'] for a in s['aliases']}
        for feedback in self.feedback(already_read=True):
            if feedback['kind'] != 'already_read':
                continue
            identity = json.loads(feedback['identity'] or '{}')
            if (feedback['candidate_id'] == work['id'] or known_ids & set(identity.get('source_ids', []))
                    or known_aliases & set(identity.get('aliases', []))):
                return False, 'Déjà lu, signalé dans tes retours.'
        item = work.get('library')
        if not item and work.get('possible_library_overlap'):
            return False, 'Titre alternatif potentiellement déjà présent : identité à résoudre.'
        if scope == 'unread':
            allowed = not item or item['statut'] == 'À lire'
            return allowed, '' if allowed else 'Déjà commencé ou terminé dans MangaTime.'
        if scope == 'discovery':
            return not bool(item), 'Déjà présent dans MangaTime.' if item else ''
        if scope == 'backlog':
            allowed = bool(item and item['statut'] == 'À lire')
            return allowed, '' if allowed else 'Hors de ta pile À lire.'
        if scope == 'resume':
            allowed = bool(item and item['statut'] in ('En pause', 'En cours'))
            return allowed, '' if allowed else 'Hors des lectures à reprendre.'
        return False, 'Périmètre inconnu.'

    def card(self, work, full=False):
        result = {k: work[k] for k in ('id', 'title', 'library', 'identity')}
        result['sources'] = []
        for s in work['sources']:
            fields = dict(s['fields'])
            if not full:
                fields['synopsis'] = fields['synopsis'][:420]
                fields['aliases'] = ' | '.join(s['aliases'][:4])
                fields['tags'] = ' | '.join(s['tags'][:25])
            result['sources'].append({'id': s['id'], 'catalogue': s['catalogue'], 'url': s['url'], 'fields': fields})
        return result

    def taste_card(self, work):
        """Repères de goût compacts : les longues listes d'alias ne sont pas du profil."""
        sources = work['sources']
        return {'id': work['id'], 'title': work['title'], 'library': work['library'],
                'genres': list(dict.fromkeys(t for s in sources for t in s['genres'])),
                'tags': list(dict.fromkeys(t for s in sources for t in s['tags']))[:35],
                'synopsis': next((s['fields']['synopsis'][:500] for s in sources if s['fields']['synopsis']), '')}

    def profile(self):
        items = self.library
        return {
            'total': len(items), 'rated': sum(x['note'] is not None for x in items),
            'backlog': sum(x['statut'] == 'À lire' for x in items),
            'principles': ['À lire signifie non lu : ce n’est pas une preuve de goût.',
                           'En pause ne signifie pas détesté. Les notes et commentaires priment.',
                           'Un abandon ou une note basse ne condamne pas tout un genre.',
                           'La demande actuelle prime sur le profil. Ne réduire le lecteur ni au murim ni au GL.'],
            'favorites': [self.taste_card(w) for w in self.works.values() if w['library'] and 'Podium' in (w['library'].get('listes') or [])],
        }

    def save_run(self, run):
        safe = {k: v for k, v in run.items() if k not in ('cancel',)}
        with self.connect() as db:
            db.execute('INSERT OR REPLACE INTO runs(id,prompt,scope,data) VALUES(?,?,?,?)',
                       (run['id'], run['prompt'], run['scope'], json.dumps(safe, ensure_ascii=False)))

        self.remember(run)

    def history(self):
        with self.connect() as db:
            rows = db.execute('SELECT data FROM runs ORDER BY created DESC,rowid DESC LIMIT 30').fetchall()
        return [json.loads(x['data']) for x in rows]

    def add_feedback(self, run_id, candidate, kind, comment):
        work = self.get(candidate)
        if not work:
            raise ValueError('Œuvre inconnue.')
        identity = {'source_ids': [s['id'] for s in work['sources']],
                    'aliases': [norm(a) for s in work['sources'] for a in s['aliases']]}
        with self.connect() as db:
            db.execute('INSERT INTO feedback(run_id,candidate_id,kind,comment,identity) VALUES(?,?,?,?,?)',
                       (run_id, candidate, kind, comment[:2000], json.dumps(identity)))
