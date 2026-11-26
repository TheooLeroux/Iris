String _normalize(String value) {
  var result = value.toLowerCase().replaceAll('&', 'and');
  for (final entry in {
    '[àâä]': 'a',
    '[éèêë]': 'e',
    '[îï]': 'i',
    '[ôö]': 'o',
    '[ùûü]': 'u',
    'ç': 'c',
    'œ': 'oe',
  }.entries) {
    result = result.replaceAll(RegExp(entry.key), entry.value);
  }
  return result.replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');
}

class ReadingTitle {
  final String title;
  final Set<String> aliases = {};
  bool proposed = false, inLibrary = false;
  ReadingTitle(this.title);

  String get source => proposed && inLibrary
      ? 'Proposé · Bibliothèque'
      : proposed
      ? 'Proposé dans tes conseils'
      : 'Bibliothèque';
}

List<ReadingTitle> readingTitles({
  required List<dynamic> history,
  required List<dynamic> library,
}) {
  final entries = <ReadingTitle>[];
  final aliases = <String, ReadingTitle>{};

  void add(
    String title,
    Iterable<String> alternatives, {
    bool proposed = false,
    bool inLibrary = false,
  }) {
    if (title.trim().isEmpty) return;
    final names = {
      title.trim(),
      ...alternatives.map((s) => s.trim()).where((s) => s.isNotEmpty),
    };
    final keys = names.map(_normalize).where((key) => key.isNotEmpty).toSet();
    if (keys.isEmpty) return;
    final matches = keys
        .map((key) => aliases[key])
        .whereType<ReadingTitle>()
        .toSet();
    final entry = matches.isEmpty
        ? ReadingTitle(title.trim())
        : entries.firstWhere(matches.contains);
    if (matches.isEmpty) entries.add(entry);
    for (final other in matches.where((other) => other != entry)) {
      entry.aliases.addAll(other.aliases);
      entry.proposed |= other.proposed;
      entry.inLibrary |= other.inLibrary;
      entries.remove(other);
    }
    entry.aliases.addAll(names);
    entry.proposed |= proposed;
    entry.inLibrary |= inLibrary;
    for (final name in entry.aliases) {
      aliases[_normalize(name)] = entry;
    }
  }

  final runs = history.whereType<Map>().toList()
    ..sort(
      (a, b) => (b['created'] is num ? b['created'] as num : 0).compareTo(
        a['created'] is num ? a['created'] as num : 0,
      ),
    );
  for (final run in runs.where((run) => run['status'] == 'done')) {
    final result = run['result'];
    if (result is! Map) continue;
    final recs = result['recommendations'] is List
        ? result['recommendations'] as List
        : [if (result['work'] is Map) result];
    for (final rec in recs.whereType<Map>()) {
      final work = rec['work'];
      if (work is! Map || work['title'] is! String) continue;
      final alternatives = <String>[];
      for (final source in (work['sources'] as List? ?? []).whereType<Map>()) {
        final fields = source['fields'];
        if (fields is Map) {
          if (fields['title'] is String) alternatives.add(fields['title']);
          if (fields['aliases'] is String) {
            alternatives.addAll((fields['aliases'] as String).split(' | '));
          }
        }
      }
      add(work['title'], alternatives, proposed: true);
    }
  }
  for (final row in library) {
    final title = row is Map
        ? row['titre']
        : row is List && row.isNotEmpty
        ? row.first
        : null;
    if (title is String) add(title, [], inLibrary: true);
  }
  return entries;
}

List<ReadingTitle> matchingReadingTitles(
  List<ReadingTitle> entries,
  String query, {
  int limit = 8,
}) {
  if (limit <= 0) return [];
  final terms = query
      .trim()
      .split(RegExp(r'\s+'))
      .map(_normalize)
      .where((term) => term.isNotEmpty)
      .toList();
  if (terms.isEmpty) {
    final recent = entries
        .where((entry) => entry.proposed)
        .take(limit < 4 ? limit : 4)
        .toList();
    return [
      ...recent,
      ...entries
          .where((entry) => entry.inLibrary && !recent.contains(entry))
          .take(limit - recent.length),
    ].take(limit).toList();
  }
  final normalized = _normalize(query);
  int rank(ReadingTitle entry) =>
      entry.aliases.any((name) => _normalize(name) == normalized)
      ? 0
      : entry.aliases.any((name) => _normalize(name).startsWith(normalized))
      ? 1
      : 2;
  final matches = entries
      .where(
        (entry) => entry.aliases.any((name) {
          final value = _normalize(name);
          return terms.every(value.contains);
        }),
      )
      .toList();
  final order = {for (var i = 0; i < entries.length; i++) entries[i]: i};
  matches.sort((a, b) {
    final comparison = rank(a).compareTo(rank(b));
    return comparison != 0 ? comparison : order[a]!.compareTo(order[b]!);
  });
  return matches.take(limit).toList();
}
