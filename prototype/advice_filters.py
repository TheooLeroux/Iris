"""Filtres explicites partagés par l'API et le conseiller."""

GENRES = {
    'action': ('Action',),
    'adventure': ('Adventure', 'Aventure'),
    'fantasy': ('Fantasy', 'Fantaisie'),
    'romance': ('Romance',),
    'comedy': ('Comedy', 'Comédie'),
    'drama': ('Drama', 'Drame'),
    'scifi': ('Sci-Fi', 'Science Fiction', 'Science-fiction'),
    'slice_of_life': ('Slice of Life', 'Tranche de vie'),
    'mystery': ('Mystery', 'Mystère'),
    'horror': ('Horror', 'Horreur'),
}

FILTER_MEANINGS = {
    'finished': 'Publication d’origine terminée obligatoire.',
    'ongoing': 'Publication d’origine en cours obligatoire (RELEASING), hors pause et annulation.',
    'short': 'De 1 à 50 chapitres confirmés, bornes incluses.',
    'long': 'Strictement plus de 50 chapitres confirmés.',
    'very_long': 'Strictement plus de 100 chapitres confirmés.',
    'country:JP': 'Origine japonaise obligatoire (manga, JP).',
    'country:KR': 'Origine coréenne obligatoire (manhwa, KR).',
    'country:CN': 'Origine chinoise obligatoire (manhua, CN).',
    **{'genre:' + key: 'Genre obligatoire dans les tags ou genres des catalogues : ' + names[0]
       for key, names in GENRES.items()},
}


def validate_filters(filters):
    if not isinstance(filters, (list, tuple)) or any(
            not isinstance(value, str) or value not in FILTER_MEANINGS for value in filters):
        raise ValueError('Filtres inconnus.')
    values = set(filters)
    for group in ({'finished', 'ongoing'}, {'short', 'long', 'very_long'},
                  {'country:JP', 'country:KR', 'country:CN'}):
        if len(values & group) > 1:
            raise ValueError('Choisis une seule option par filtre de publication, longueur ou origine.')
