"""Serveur local sans dépendances. Lancer avec python prototype/app.py."""
import argparse
import getpass
import json
import os
import secrets
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from agent import Advisor, Cancelled, MODEL, OpenAI
from catalogues import Catalogues
import reading_links
from storage import ROOT, Store
from advice_filters import validate_filters

DEFAULT_SCOPE = 'discovery'


class Application:
    def __init__(self, key, port):
        self.store = Store()
        self.advisor = Advisor(self.store, Catalogues(self.store), OpenAI(key))
        self.port = port
        self.csrf = secrets.token_urlsafe(32)
        self.jobs = {}
        self.lock = threading.Lock()

    @staticmethod
    def public(job):
        return {k: v for k, v in job.items() if k != 'cancel'}

    def start(self, prompt, scope=DEFAULT_SCOPE, filters=(), library=None, count=5, mode="guided"):
        with self.lock:
            if any(not j.get('saved') for j in self.jobs.values()):
                raise ValueError('Une recherche est déjà en cours. Attends sa fin ou annule-la.')
            if library is not None:
                if not isinstance(library, list) or any(not isinstance(r, dict) or not isinstance(r.get('titre'), str) or not r['titre'].strip() or not isinstance(r.get('statut'), str) for r in library):
                    raise ValueError('Export MangaTime invalide.')
                library = [dict({'note':None,'note_privee':None,'listes':[],'type':None}, **r) for r in library]
            store = Store(self.store.runtime, library=library, filters=filters)
            self.store = store
            self.advisor.store = store
            self.advisor.catalogues.store = store
            job = {'count':count, 'mode':mode, 'filters':list(filters), 'id': secrets.token_hex(8), 'prompt': prompt, 'scope': scope, 'status': 'running',
                   'step': 'Démarrage', 'created': time.time(), 'input_tokens': 0, 'output_tokens': 0,
                   'cost_usd': 0.0, 'cancel': threading.Event(), 'trace': []}
            self.jobs[job['id']] = job

        def worker():
            try:
                result = self.advisor.run(job, lambda message: job.update(step=message))
                if job['cancel'].is_set():
                    raise Cancelled()
                job.update(result=result, status='done', step='Recherche terminée')
            except Cancelled:
                job.update(status='cancelled', step='Recherche annulée')
            except Exception as error:
                # Les erreurs OpenAI sont déjà nettoyées ; ne jamais transmettre les requêtes HTTP.
                job.update(status='error', error=str(error)[:1000], step='Recherche interrompue')
            finally:
                job['duration_seconds'] = round(time.time() - job['created'], 1)
                try:
                    store.save_run(self.public(job))
                finally:
                    job['saved'] = True
        threading.Thread(target=worker, daemon=True).start()
        return self.public(job)


def handler(application):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, format, *args):
            # Les requêtes ou réponses et données privées ne vont pas dans les logs.
            pass

        def allowed_host(self):
            return self.headers.get('Host') in (f'127.0.0.1:{application.port}', f'localhost:{application.port}')

        def send(self, status, value, content_type='application/json; charset=utf-8'):
            data = json.dumps(value, ensure_ascii=False).encode() if isinstance(value, (dict, list)) else value
            self.send_response(status)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(len(data)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.send_header('Referrer-Policy', 'no-referrer')
            self.send_header('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data: https://cdn.mangaupdates.com https://*.anilist.co https://uploads.mangadex.org; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'")
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            if not self.allowed_host():
                return self.send(403, {'error': 'Hôte interdit.'})
            path = urllib.parse.urlsplit(self.path).path
            if path in ('/api/reading/search', '/api/reading/chapters'):
                query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
                try:
                    if path.endswith('/search'):
                        result = reading_links.search(application.advisor.catalogues, query.get('title', [''])[0])
                    else:
                        result = reading_links.reading_links(application.advisor.catalogues,
                                                             query.get('id', [''])[0], query.get('chapters', [''])[0],
                                                             application.advisor.client.search_reading)
                except (ValueError, KeyError, OSError) as error:
                    return self.send(400, {'error': str(error)[:300] or 'Catalogue indisponible.'})
                return self.send(200, result)
            if path.startswith('/api/cover/'):
                source_id = urllib.parse.unquote(path.removeprefix('/api/cover/'))
                if source_id not in application.store.source_index:
                    return self.send(404, {'error': 'Fiche inconnue.'})
                try:
                    url = application.advisor.catalogues.cover_url(source_id)
                except (ValueError, OSError, KeyError):
                    return self.send(503, {'error': 'Catalogue indisponible.'})
                return self.send(200, {'source_id': source_id, 'url': url})
            if path == '/api/session':
                return self.send(200, {'csrf': application.csrf})
            if path == '/api/bootstrap':
                return self.send(200, {'csrf': application.csrf, 'model': MODEL, 'profile': application.store.profile(),
                    'audit_date': application.store.audit_date, 'history': application.store.history(),
                    'active_job': next((application.public(j) for j in application.jobs.values() if j['status'] == 'running'), None)})
            if path == '/api/library':
                return self.send(200, [application.store.card(w, full=True) for w in list(application.store.works.values()) if w['library']])
            if path == '/api/history':
                return self.send(200, application.store.history())
            if path.startswith('/api/jobs/'):
                job = application.jobs.get(path.split('/')[-1])
                return self.send(200, application.public(job)) if job else self.send(404, {'error': 'Recherche inconnue.'})
            if path.startswith('/api/'):
                return self.send(404, {'error': 'Route inconnue.'})
            name = {'/': 'index.html', '/app.js': 'app.js', '/style.css': 'style.css'}.get(path)
            if not name:
                return self.send(404, {'error': 'Page inconnue.'})
            mime = {'index.html': 'text/html; charset=utf-8', 'app.js': 'text/javascript; charset=utf-8', 'style.css': 'text/css; charset=utf-8'}[name]
            return self.send(200, (ROOT / 'static' / name).read_bytes(), mime)

        def do_POST(self):
            origin = self.headers.get('Origin')
            if (not self.allowed_host() or self.headers.get('X-Reco-Token') != application.csrf
                    or origin and origin not in (f'http://127.0.0.1:{application.port}', f'http://localhost:{application.port}')):
                return self.send(403, {'error': 'Requête locale non autorisée.'})
            try:
                length = int(self.headers.get('Content-Length', 0))
                if length <= 0 or length > (8000000 if self.path == '/api/advise' else 16000):
                    raise ValueError('Taille de requête incorrecte.')
                body = json.loads(self.rfile.read(length))
                if self.path == '/api/advise':
                    prompt = str(body.get('prompt', '')).strip()
                    scope = body.get('scope', DEFAULT_SCOPE)
                    if not 3 <= len(prompt) <= 4000:
                        raise ValueError('Écris une demande de 3 à 4 000 caractères.')
                    if scope not in ('unread', 'discovery', 'backlog', 'resume'):
                        raise ValueError('Périmètre invalide.')
                    filters = body.get('filters', [])
                    validate_filters(filters)
                    count, mode = body.get('count',5), body.get('mode','guided')
                    if type(count) is not int or not 1 <= count <= 5 or mode not in ('guided','absolute'):
                        raise ValueError('Nombre ou mode de consigne invalide.')
                    if filters or 'library' in body or 'count' in body or 'mode' in body:
                        return self.send(202, application.start(prompt, scope, filters, body.get('library'), count, mode))
                    return self.send(202, application.start(prompt, scope))
                if self.path == '/api/cancel':
                    job = application.jobs.get(body.get('id'))
                    if not job:
                        raise ValueError('Recherche inconnue.')
                    job['cancel'].set()
                    return self.send(200, {'ok': True})
                if self.path == '/api/feedback':
                    kind = body.get('kind')
                    if kind not in ('interested', 'off_topic', 'already_read', 'not_today'):
                        raise ValueError('Retour invalide.')
                    run_id = body.get('run_id')
                    job = application.jobs.get(run_id) or next((r for r in application.store.history() if r['id'] == run_id), None)
                    candidate = feedback_candidate(job, body.get('candidate_id'))
                    application.store.add_feedback(run_id, candidate, kind, str(body.get('comment', '')))
                    return self.send(200, {'ok': True})
                return self.send(404, {'error': 'Route inconnue.'})
            except (ValueError, KeyError, TypeError) as error:
                return self.send(400, {'error': str(error)[:500]})
    return Handler


def feedback_candidate(job, requested):
    """Un retour vise exactement une œuvre du conseil, ancien ou à cinq choix."""
    result = job.get('result', {}) if job else {}
    if result.get('status') != 'recommendation':
        raise ValueError('Aucune œuvre conseillée pour cette recherche.')
    if 'recommendations' in result:
        allowed = {r['candidate_id'] for r in result['recommendations']}
        if not requested or requested not in allowed:
            raise ValueError('Choisis une œuvre effectivement proposée dans cette sélection.')
        return requested
    candidate = result.get('candidate_id')
    if not candidate or requested and requested != candidate:
        raise ValueError('Œuvre absente de ce conseil.')
    return candidate


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Conseiller de lecture personnel — local uniquement')
    parser.add_argument('--port', type=int, default=8765)
    args = parser.parse_args()
    key = os.environ.get('OPENAI_API_KEY', '').strip() or getpass.getpass('Clé API OpenAI (masquée, mémoire seulement) : ').strip()
    if not key:
        raise SystemExit('Clé manquante.')
    application = Application(key, args.port)
    server = ThreadingHTTPServer(('127.0.0.1', args.port), handler(application))
    print(f'Prêt : http://127.0.0.1:{args.port} — modèle {MODEL}', flush=True)
    print('Clé uniquement en mémoire. Ctrl+C pour arrêter.', flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.server_close()
