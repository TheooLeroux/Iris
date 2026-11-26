"""Contrôles de pages de chapitre : identité, numéro et accès effectif."""
import ipaddress
import json
import re
import socket
import unicodedata
import urllib.request
from decimal import Decimal
from html.parser import HTMLParser
from urllib.parse import urlsplit

from storage import norm

MAX_PAGE_BYTES = 2_000_000
NUMBER = r'([0-9]+(?:[.,][0-9]+)?)'
CHAPTER = re.compile(
    r'(?:\b(?:chapters?|chapitres?|ch\.?|episodes?|ep\.?|cap[ií]tulos?|capitoli?|kapitel)\s*[.#:]?\s*' + NUMBER
    + r'|第?\s*' + NUMBER + r'\s*(?:話|话|章|회)|#\s*' + NUMBER + r')', re.I)
READER = re.compile(r'reader|reading-content|chapter-content|chapter-image|chapter-img|comic-page|page-break', re.I)
BLOCKED = re.compile(r'chapter\s+(?:is\s+|has\s+been\s+)?(?:not\s+found|unavailable|removed)|chapitre\s+indisponible|chapter\s+does\s+not\s+exist', re.I)


def has_identity(text, titles, number):
    text = unicodedata.normalize('NFKC', text)
    found = {format(Decimal(value.replace(',', '.')).normalize(), 'f')
             for match in CHAPTER.finditer(text) for value in match.groups() if value}
    return number in found and any(len(norm(title)) >= 3 and norm(title) in norm(text) for title in titles)


class ChapterPage(HTMLParser):
    def __init__(self, html, url):
        super().__init__(convert_charrefs=True)
        self.url = url
        self.headings, self.scripts, self.buttons, self.text = [], [], [], []
        self.stack, self.captures = [], []
        self.reader_images = 0
        self.feed(html)

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        parent_reader = bool(self.stack and self.stack[-1][1])
        reader = parent_reader or bool(READER.search((attrs.get('class') or '') + ' ' + (attrs.get('id') or '')))
        if tag == 'meta' and (attrs.get('property') or attrs.get('name')) in ('og:title', 'twitter:title'):
            self.headings.append(attrs.get('content') or '')
        if tag in ('title', 'h1', 'script', 'button', 'a'):
            self.captures.append({'tag': tag, 'text': [], 'type': attrs.get('type')})
        if tag == 'img' and reader:
            source = attrs.get('data-src') or attrs.get('data-lazy-src') or attrs.get('src') or ''
            description = source + ' ' + (attrs.get('alt') or '') + ' ' + (attrs.get('class') or '')
            if (source and not source.startswith('data:') and attrs.get('width') != '1' and attrs.get('height') != '1'
                    and not re.search(r'logo|avatar|banner|icon|cover', description, re.I)):
                self.reader_images += 1
        if tag not in ('area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'param', 'source', 'track', 'wbr'):
            self.stack.append((tag, reader))

    def handle_endtag(self, tag):
        for index in range(len(self.captures) - 1, -1, -1):
            capture = self.captures[index]
            if capture['tag'] == tag:
                text = ' '.join(capture['text'])
                if tag in ('title', 'h1'):
                    self.headings.append(text)
                elif tag == 'script':
                    self.scripts.append((capture['type'], text))
                else:
                    self.buttons.append(text)
                del self.captures[index]
                break
        for index in range(len(self.stack) - 1, -1, -1):
            if self.stack[index][0] == tag:
                del self.stack[index:]
                break

    def handle_data(self, data):
        for capture in self.captures:
            capture['text'].append(data)
        if not any(tag in ('script', 'style') for tag, _ in self.stack):
            self.text.append(data)

    def availability(self, titles, number):
        if not any(has_identity(heading, titles, number) for heading in self.headings):
            return None
        if BLOCKED.search(' '.join(self.text)):
            return None
        if any(re.search(r'just a moment|access denied|page not found|404 not found', heading, re.I) for heading in self.headings):
            return None
        # A preview on a shop is not advertised as a complete free chapter.
        purchase = any(re.search(r'add to cart|buy (?:now|chapter)|purchase|acheter|カート|購入する', label, re.I) for label in self.buttons)
        for kind, script in self.scripts:
            if kind == 'application/ld+json':
                try:
                    product = json.loads(script)
                    available = self._product_offer(product, titles, number)
                    if not available and self._product_offer(product, titles, number, unavailable=True):
                        return None
                    purchase |= available
                except (ValueError, TypeError):
                    pass
        # Public metadata for a chapter sold individually by Sony Reader Store.
        if urlsplit(self.url).hostname == 'ebookstore.sony.jp' and '/id/' in urlsplit(self.url).path:
            purchase |= any('applyPriceIncludeTax' in script for _, script in self.scripts)
        if purchase:
            if any(re.search(r'pre.?order|précommande|予約受付|配信予定', heading, re.I) for heading in self.headings):
                return None
            return 'purchase'
        if any(re.search(r'preview|extrait|sample|試し読み', heading, re.I) for heading in self.headings):
            return None
        if self.reader_images:
            return 'reader'
        for _, script in self.scripts:
            if (re.search(r'ts_reader\.run|["\x27](?:chapterImages|chapter_images|readerPages|pageList)["\x27]', script)
                    and re.search(r'https?(?::|\\u003[aA])(?:/|\\/).+?\.(?:jpe?g|png|webp)', script, re.I)):
                return 'reader'
        return None

    @classmethod
    def _product_offer(cls, value, titles, number, unavailable=False):
        if isinstance(value, list):
            return any(cls._product_offer(item, titles, number, unavailable) for item in value)
        if not isinstance(value, dict):
            return False
        if value.get('@type') in ('Product', 'Book') and has_identity(str(value.get('name', '')), titles, number):
            offers = value.get('offers') or []
            offers = [offers] if isinstance(offers, dict) else offers
            statuses = ('OutOfStock', 'SoldOut', 'Discontinued', 'PreOrder', 'PreSale') if unavailable else ('InStock', 'LimitedAvailability', 'OnlineOnly')
            if any(isinstance(offer, dict) and str(offer.get('availability', '')).rsplit('/', 1)[-1] in statuses for offer in offers):
                return True
        return cls._product_offer(value.get('@graph'), titles, number, unavailable)


def public_url(url):
    parsed = urlsplit(url)
    if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password or parsed.port not in (None, 443):
        raise ValueError('URL de lecture invalide.')
    addresses = socket.getaddrinfo(parsed.hostname, 443, type=socket.SOCK_STREAM)
    if not addresses or any(not ipaddress.ip_address(address[4][0]).is_global for address in addresses):
        raise ValueError('URL de lecture non publique.')


class PublicRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        public_url(new_url)
        return super().redirect_request(request, response, code, message, headers, new_url)


def fetch_chapter_page(url):
    public_url(url)
    request = urllib.request.Request(url, headers={'User-Agent': 'Iris/1.0 (chapter availability)', 'Accept': 'text/html,application/xhtml+xml', 'Accept-Encoding': 'identity'})
    with urllib.request.build_opener(PublicRedirect()).open(request, timeout=10) as response:
        if response.status != 200 or response.headers.get_content_type() not in ('text/html', 'application/xhtml+xml'):
            raise ValueError('Page de chapitre indisponible.')
        raw = response.read(MAX_PAGE_BYTES + 1)
        if len(raw) > MAX_PAGE_BYTES:
            raise ValueError('Page trop volumineuse pour être vérifiée.')
        return ChapterPage(raw.decode(response.headers.get_content_charset() or 'utf-8', errors='replace'), response.url)
