"""Moteur embarqué Android : appels directs et SQLite, aucun serveur HTTP."""
import json
import re
import secrets
import shutil
import threading
import time
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlsplit

from advice_filters import validate_filters
from agent import Advisor, Cancelled, OpenAI
from catalogues import Catalogues
from storage import Store
import reading_links
from mangatime import MangaTime


class NativeOpenAI(OpenAI):
    """HTTPS Android et certificats système, clé transmise uniquement en mémoire."""
    def __init__(self, key, transport):
        super().__init__(key)
        self.transport = transport

    def send(self, payload):
        response = json.loads(str(self.transport.post(json.dumps(payload), self._key)))
        if response.get('network_error'):
            raise OSError('Connexion à OpenAI impossible. Vérifie Internet et réessaie.')
        data = json.loads(response['body'])
        if response['status'] >= 400:
            message = str((data.get('error') or {}).get('message') or 'Requête refusée.')
            message = re.sub(r'sk-[A-Za-z0-9_.*-]+', '[clé masquée]', message.replace(self._key, '[clé masquée]'))
            raise ValueError(f"OpenAI HTTP {response['status']} : {message[:500]}")
        return data


class Engine:
    def __init__(self, runtime, data_root=None, transport=None, mangatime_transport=None):
        self.runtime = Path(runtime)
        self.data_root = Path(data_root) if data_root else Path(__file__).parent / 'seed'
        self.transport = transport
        self.runtime.mkdir(parents=True, exist_ok=True)
        database = self.runtime / 'recolecture.sqlite3'
        # Le premier lancement reprend l'historique de cette version personnelle.
        # Une mise à jour ne remplace jamais la base du téléphone.
        seed_database = self.data_root / 'recolecture.sqlite3'
        if not database.exists() and seed_database.exists():
            temporary = database.with_suffix('.import')
            shutil.copyfile(seed_database, temporary)
            temporary.replace(database)
        # La version personnelle de transition conserve son ancienne bibliothèque
        # dans les données privées avant les futures APK distribuées sans données.
        library_root = self.runtime / 'library-data'
        for relative in ('mangatime-20261119-134639-04c64935.json',
                         'recherche-catalogues/audit-complet/resultats-revus.json',
                         'recherche-catalogues/vowrune-identification.json'):
            source, target = self.data_root / relative, library_root / relative
            if not target.exists() and source.exists():
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, target)
        self.data_root = library_root
        self.store = Store(self.runtime, data_root=self.data_root)
        self.mangatime = MangaTime(database, mangatime_transport)
        self.catalogues = Catalogues(self.store, self.runtime)
        self.jobs = {}
        self.lock = threading.Lock()
        for run in self.store.history():
            if run.get('status') == 'running':
                run.update(status='error', error='Recherche interrompue à la fermeture de l’application.')
                self.store.save_run(run)

    @staticmethod
    def public(job):
        return {k: v for k, v in job.items() if k not in ('cancel', 'saved')}

    def client(self, key):
        return NativeOpenAI(key, self.transport) if self.transport else OpenAI(key)

    def start(self, body, key):
        if not key:
            raise ValueError('Ajoute ta clé API dans les réglages pour lancer les conseils.')
        prompt = str(body.get('prompt', '')).strip()
        count, mode, filters = body.get('count', 5), body.get('mode', 'guided'), body.get('filters', [])
        if not 3 <= len(prompt) <= 4000:
            raise ValueError('Écris une demande de 3 à 4 000 caractères.')
        validate_filters(filters)
        if type(count) is not int or not 1 <= count <= 5 or mode not in ('guided', 'absolute'):
            raise ValueError('Nombre ou mode de consigne invalide.')
        library = body.get('library')
        if library is not None:
            if not isinstance(library, list) or any(not isinstance(r, dict) or not isinstance(r.get('titre'), str)
                    or not r['titre'].strip() or not isinstance(r.get('statut'), str) for r in library):
                raise ValueError('Export MangaTime invalide.')
            library = [dict({'note': None, 'note_privee': None, 'listes': [], 'type': None}, **r) for r in library]
        library = self.mangatime.library(library if library is not None else self.store.library)
        with self.lock:
            if any(not job.get('saved') for job in self.jobs.values()):
                raise ValueError('Une recherche est déjà en cours.')
            store = Store(self.runtime, library=library, filters=filters, data_root=self.data_root)
            self.store = store
            self.catalogues.store = store
            advisor = Advisor(store, self.catalogues, self.client(key))
            job = {'id': secrets.token_hex(8), 'prompt': prompt, 'scope': 'discovery', 'count': count,
                   'mode': mode, 'filters': filters, 'status': 'running', 'step': 'Démarrage',
                   'created': time.time(), 'input_tokens': 0, 'output_tokens': 0, 'cost_usd': 0.0,
                   'cancel': threading.Event(), 'trace': []}
            self.store.save_run(self.public(job))
            self.jobs[job['id']] = job

        def work():
            try:
                result = advisor.run(job, lambda message: job.update(step=message))
                if job['cancel'].is_set():
                    raise Cancelled()
                job.update(result=result, status='done', step='Recherche terminée')
            except Cancelled:
                job.update(status='cancelled', step='Recherche annulée')
            except Exception as error:
                job.update(status='error', error=str(error)[:1000], step='Recherche interrompue')
            finally:
                job['duration_seconds'] = round(time.time() - job['created'], 1)
                try:
                    store.save_run(self.public(job))
                finally:
                    job['saved'] = True
        threading.Thread(target=work, daemon=True).start()
        return self.public(job)

    def request(self, path, body=None, key=''):
        uri = urlsplit(path)
        route = uri.path
        query = parse_qs(uri.query)
        if route.startswith('mangatime/'):
            body = body or {}
            if route == 'mangatime/library':
                rows = body.get('library')
                if rows is not None:
                    if not isinstance(rows, list) or any(not isinstance(r, dict)
                            or not isinstance(r.get('titre'), str) or not r['titre'].strip()
                            or not isinstance(r.get('statut'), str) for r in rows):
                        raise ValueError('Export MangaTime invalide.')
                    path = self.data_root / 'mangatime-20261119-134639-04c64935.json'
                    # L'accès à la synchronisation ne remplace jamais la base SQLite.
                    with self.lock:
                        temporary = path.with_suffix('.tmp')
                        temporary.write_text(json.dumps(rows, ensure_ascii=False), encoding='utf-8')
                        temporary.replace(path)
                return self.mangatime.library(rows if rows is not None else self.store.library)
            work = body.get('work') or {}
            if route == 'mangatime/state':
                return self.mangatime.state(work)
            if route == 'mangatime/search':
                return self.mangatime.search(work)
            if route == 'mangatime/set':
                return self.mangatime.set_planned(work, body.get('id'), body.get('added'))
        if route == 'history':
            return self.store.history()
        if route.startswith('cover/'):
            return {'url': self.catalogues.cover_url(unquote(route[6:]))}
        if route == 'reading/search':
            return reading_links.search(self.catalogues, query.get('title', [''])[0])
        if route == 'reading/chapters':
            # MangaDex reste utilisable sans clé ; la recherche Web nécessite OpenAI.
            result = reading_links.reading_links(self.catalogues, query.get('id', [''])[0],
                query.get('chapters', [''])[0], self.client(key).search_reading if key else None)
            if not key:
                result['warnings'].append('Ajoute une clé API dans les réglages pour chercher aussi sur le Web.')
            return result
        if route == 'advise':
            return self.start(body or {}, key)
        if route.startswith('jobs/'):
            job = self.jobs.get(route[5:])
            if not job:
                raise ValueError('Recherche inconnue.')
            return self.public(job)
        raise ValueError('Action inconnue.')

    def call(self, path, raw_body, key):
        try:
            return json.dumps({'data': self.request(path, json.loads(raw_body) if raw_body else None, key)}, ensure_ascii=False)
        except (ValueError, KeyError) as error:
            return json.dumps({'error': str(error)[:500]}, ensure_ascii=False)
        except OSError:
            return json.dumps({'error': 'Connexion impossible. Vérifie l’accès à Internet et réessaie.'}, ensure_ascii=False)
