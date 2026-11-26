"""Ajout explicite de conseils à MangaTime ; session détenue par Android."""
import json
import re
import sqlite3
import threading
from contextlib import contextmanager
from urllib.parse import urlencode

from storage import norm

UUID = re.compile(r'[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}\Z')
STATUSES = ['En cours', 'Terminé', 'Abandonné', 'En pause', 'À lire']


class MangaTimeError(ValueError):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


class MangaTime:
    def __init__(self, database, transport):
        self.database, self.transport = database, transport
        self.lock = threading.RLock()
        with self.connect() as db:
            db.execute('CREATE TABLE IF NOT EXISTS mangatime_links '
                       '(work_key TEXT PRIMARY KEY, manga_id TEXT, title TEXT, owned INTEGER, row_json TEXT)')

    @contextmanager
    def connect(self):
        db = sqlite3.connect(self.database)
        db.row_factory = sqlite3.Row
        try:
            with db:
                yield db
        finally:
            db.close()

    def account(self):
        return str(self.transport.account()) if self.transport else ''

    def key(self, work):
        title = work.get('title')
        if not isinstance(title, str) or not 1 <= len(title.strip()) <= 500:
            raise ValueError('Titre de recommandation invalide.')
        return self.account() + ':' + norm(title)

    def api(self, method, path):
        if self.transport is None:
            raise ValueError('La connexion MangaTime nécessite l’application Android.')
        response = json.loads(str(self.transport.request(method, path)))
        status = response['status']
        if status == 401:
            raise MangaTimeError(status, 'Session MangaTime expirée. Importe-la à nouveau dans les réglages.')
        if status in (403, 429):
            raise MangaTimeError(status, 'MangaTime refuse temporairement l’accès. Réessaie plus tard.')
        if not 200 <= status < 300:
            raise MangaTimeError(status, 'Action MangaTime non confirmée. Actualise avant de réessayer.')
        return json.loads(response['body']) if response.get('body') else {}

    def detail(self, manga_id):
        if not isinstance(manga_id, str) or not UUID.fullmatch(manga_id):
            raise ValueError('Identifiant MangaTime invalide.')
        data = self.api('GET', '/api/v1/mangas/' + manga_id)['data']
        if data.get('id') != manga_id or 'user_related' not in data:
            raise ValueError('Fiche MangaTime incomplète. Aucune modification effectuée.')
        related = data['user_related']
        # Hors bibliothèque, l’API renvoie aussi un objet de préférences sans statut.
        if isinstance(related, dict) and set(related) <= {'custom_list_ids', 'recommendation_feedback'} and not related.get('custom_list_ids'):
            data['user_related'] = related = None
        if related is not None and (not isinstance(related, dict)
                or type(related.get('status')) is not int or related['status'] not in range(5)):
            raise ValueError('Statut MangaTime non reconnu. Aucune modification effectuée.')
        return data

    def search(self, work):
        self.key(work)
        data = self.api('GET', '/api/v1/search?' + urlencode({'keyword': work['title']}))
        rows = data['data']['manga']
        if not isinstance(rows, list):
            raise ValueError('Résultats MangaTime illisibles.')
        return [{'id': r['id'], 'title': r['title'],
                 'status': STATUSES[r['user_related']['status']] if isinstance(r.get('user_related'), dict)
                 and type(r['user_related'].get('status')) is int and r['user_related']['status'] in range(5) else None}
                for r in rows if UUID.fullmatch(r.get('id', ''))][:30]

    def save(self, key, data, owned):
        related = data.get('user_related')
        row = None if not related else {'titre': data['title'], 'statut': STATUSES[related['status']],
            'note': related.get('rating'), 'note_privee': related.get('private_note'), 'listes': [],
            'dernier_chapitre_lu': related.get('last_chapter_number'),
            'chapitres_total': data.get('chapters_count'), 'type': None}
        with self.connect() as db:
            db.execute('INSERT OR REPLACE INTO mangatime_links VALUES(?,?,?,?,?)',
                       (key, data['id'], data['title'], int(owned), json.dumps(row, ensure_ascii=False)))
        return {'id': data['id'], 'title': data['title'],
                'added': bool(related and related['status'] == 4),
                'can_remove': bool(owned and related and related['status'] == 4),
                'status': row['statut'] if row else None}

    def state(self, work):
        with self.lock, self.connect() as db:
            link = db.execute('SELECT * FROM mangatime_links WHERE work_key=?', (self.key(work),)).fetchone()
            if link is None:
                return {'added': False, 'can_remove': False}
            return self.save(self.key(work), self.detail(link['manga_id']), link['owned'])

    def set_planned(self, work, manga_id, added):
        if type(added) is not bool:
            raise ValueError('Action MangaTime invalide.')
        key = self.key(work)
        with self.lock, self.connect() as db:
            link = db.execute('SELECT * FROM mangatime_links WHERE work_key=?', (key,)).fetchone()
            data = self.detail(manga_id)
            related = data.get('user_related')
            owned = bool(link and link['manga_id'] == manga_id and link['owned'])
            if added:
                if related:
                    # Ne change jamais une lecture commencée ni un ajout déjà présent.
                    return self.save(key, data, owned)
                # Journal avant envoi : une réponse perdue sera réconciliée au prochain état.
                self.save(key, data, True)
                try:
                    self.api('POST', '/api/v1/me/library/mangas/' + manga_id + '/plan-to-read')
                except MangaTimeError as error:
                    if 400 <= error.status < 500:
                        self.save(key, data, False)
                    raise
                owned = True
            else:
                if not owned:
                    raise ValueError('Seuls les ajouts effectués depuis Iris peuvent être annulés ici.')
                if related is None:
                    return self.save(key, data, False)
                if related['status'] != 4 or any(related.get(k) for k in
                        ('progress', 'last_chapter_number', 'rating', 'private_note', 'custom_list_ids')):
                    self.save(key, data, owned)
                    raise ValueError('Cette lecture a été modifiée dans MangaTime. Gère-la directement dans MangaTime.')
                self.api('DELETE', '/api/v1/me/library/mangas/' + manga_id)
            data = self.detail(manga_id)
            state = self.save(key, data, owned if data.get('user_related') else False)
            if state['added'] != added or (not added and data.get('user_related')):
                raise ValueError('Modification non confirmée par MangaTime. Actualise son état.')
            return state

    def library(self, rows):
        result = list(rows)
        with self.connect() as db:
            links = db.execute('SELECT * FROM mangatime_links WHERE work_key LIKE ?',
                               (self.account() + ':%',)).fetchall()
        for link in links:
            row = json.loads(link['row_json'])
            names = {norm(link['title']), link['work_key'].split(':', 1)[1]}
            if row:
                if not any(norm(r['titre']) in names for r in result):
                    result.append(row)
                else:
                    result = [dict(r, statut=row['statut']) if norm(r['titre']) in names and r['statut'] == 'À lire' else r for r in result]
            elif link['owned'] == 0:
                result = [r for r in result if norm(r['titre']) not in names or r['statut'] != 'À lire'
                          or any(r.get(k) for k in ('note', 'note_privee', 'dernier_chapitre_lu', 'listes'))]
        return result
