import 'package:flutter/material.dart';
import 'advice.dart' show adviceFilterLabel;
import 'recommendation_title.dart';

const _ink = Color(0xff302923);
const _muted = Color(0xff73675e);
const _line = Color(0xffe5ded3);
const _accent = Color(0xff8d392c);
const _tint = Color(0xfff4e9e0);

List<Map> historyRecommendations(Map run) {
  final result = run['result'];
  if (result is! Map) return [];
  final recommendations = result['recommendations'];
  return (recommendations is List
          ? recommendations
          : [if (result['work'] is Map) result])
      .whereType<Map>()
      .where((r) => r['work'] is Map)
      .toList();
}

DateTime? _created(Map run) {
  final value = run['created'];
  if (value is num) {
    return DateTime.fromMillisecondsSinceEpoch(
      (value * 1000).round(),
    ).toLocal();
  }
  return value is String ? DateTime.tryParse(value)?.toLocal() : null;
}

String _time(DateTime? value) => value == null
    ? ''
    : '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
const _months = [
  'janvier',
  'février',
  'mars',
  'avril',
  'mai',
  'juin',
  'juillet',
  'août',
  'septembre',
  'octobre',
  'novembre',
  'décembre',
];
String _date(DateTime? value) => value == null
    ? 'Date inconnue'
    : '${value.day} ${_months[value.month - 1]} ${value.year}';
String _day(DateTime? value) {
  if (value == null) return 'Date inconnue';
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final date = DateTime(value.year, value.month, value.day);
  if (date == today) return 'Aujourd’hui';
  if (date == DateTime(today.year, today.month, today.day - 1)) return 'Hier';
  return _date(value);
}

String _fold(String value) {
  var result = value.toLowerCase();
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
  return result;
}

String _outcome(Map run) {
  if (run['status'] == 'error') return 'Recherche interrompue';
  if (run['status'] == 'cancelled') return 'Recherche annulée';
  if (run['status'] == 'running') return 'Recherche en cours';
  if (run['result']?['status'] == 'clarification') return 'Précision demandée';
  return 'Aucune proposition';
}

class HistoryPage extends StatefulWidget {
  final bool active;
  final int revision;
  final Future<List<dynamic>> Function() load;
  final Future<String?> Function(List) cover;
  final Widget Function(Map)? recommendationActions;
  const HistoryPage({
    super.key,
    this.active = true,
    this.revision = 0,
    required this.load,
    required this.cover,
    this.recommendationActions,
  });

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  final query = TextEditingController();
  List<Map> runs = [];
  final coverCache = <String, Future<String?>>{};
  bool loading = false, loaded = false;
  String? error;

  Future<String?> _cover(List sources) {
    final key = sources
        .whereType<Map>()
        .map((source) => source['id'])
        .whereType<String>()
        .join('|');
    if (key.isEmpty) return Future.value(null);
    return coverCache.putIfAbsent(
      key,
      () => widget.cover(sources).catchError((Object _) => null),
    );
  }

  @override
  void initState() {
    super.initState();
    if (widget.active) _reload();
  }

  @override
  void didUpdateWidget(covariant HistoryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active &&
        (!oldWidget.active || widget.revision != oldWidget.revision)) {
      _reload();
    }
  }

  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    if (loading) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final rows = await widget.load();
      if (!mounted) return;
      setState(() {
        runs = rows.whereType<Map>().toList()
          ..sort(
            (a, b) => (_created(b) ?? DateTime(1970)).compareTo(
              _created(a) ?? DateTime(1970),
            ),
          );
        loaded = true;
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'Impossible de charger l’historique. Réessaie de charger les données locales.',
        );
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void _open(Map run, [int? index]) {
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _HistoryRequestPage(
          run: run,
          selectedIndex: index,
          cover: _cover,
          recommendationActions: widget.recommendationActions,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final needle = _fold(query.text.trim());
    final filtered = runs
        .where(
          (run) =>
              needle.isEmpty ||
              _fold('${run['prompt']}').contains(needle) ||
              historyRecommendations(
                run,
              ).any((rec) => _fold('${rec['work']['title']}').contains(needle)),
        )
        .toList();
    final groups = <String, List<Map>>{};
    for (final run in filtered) {
      groups.putIfAbsent(_day(_created(run)), () => []).add(run);
    }
    final total = runs.fold<int>(
      0,
      (count, run) => count + historyRecommendations(run).length,
    );
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: RefreshIndicator(
          color: _accent,
          onRefresh: _reload,
          child: ListView(
            key: const PageStorageKey('history-scroll'),
            physics: const AlwaysScrollableScrollPhysics(),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Historique',
                      style: TextStyle(
                        fontFamily: 'serif',
                        fontSize: 28,
                        color: _ink,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Actualiser l’historique',
                    onPressed: loading ? null : _reload,
                    icon: const Icon(
                      Icons.refresh_rounded,
                      color: _accent,
                      size: 21,
                    ),
                  ),
                ],
              ),
              Text(
                loaded
                    ? '${runs.length} recherche${runs.length > 1 ? 's' : ''} · $total proposition${total > 1 ? 's' : ''}'
                    : 'Tes demandes et les lectures proposées.',
                style: const TextStyle(fontSize: 12, color: _muted),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: query,
                onChanged: (_) => setState(() {}),
                style: const TextStyle(fontSize: 14, color: _ink),
                decoration: InputDecoration(
                  hintText: 'Une demande ou un titre…',
                  hintStyle: const TextStyle(color: _muted),
                  prefixIcon: const Icon(
                    Icons.search_rounded,
                    size: 20,
                    color: _muted,
                  ),
                  suffixIcon: query.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Effacer la recherche',
                          onPressed: () => setState(query.clear),
                          icon: const Icon(Icons.close_rounded, size: 18),
                        ),
                  filled: true,
                  fillColor: Colors.white.withValues(alpha: .65),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: _line),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: _accent),
                  ),
                ),
              ),
              if (loading)
                const Padding(
                  padding: EdgeInsets.only(top: 14),
                  child: LinearProgressIndicator(minHeight: 2, color: _accent),
                ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        error!,
                        style: const TextStyle(
                          fontSize: 13,
                          color: _accent,
                          height: 1.4,
                        ),
                      ),
                      if (runs.isNotEmpty)
                        const Text(
                          'Les recherches déjà chargées restent disponibles.',
                          style: TextStyle(fontSize: 12, color: _muted),
                        ),
                      TextButton.icon(
                        onPressed: loading ? null : _reload,
                        icon: const Icon(Icons.refresh, size: 16),
                        label: const Text('Réessayer'),
                      ),
                    ],
                  ),
                ),
              if (!loading && error == null && runs.isEmpty)
                const _EmptyHistory(
                  icon: Icons.history_rounded,
                  title: 'Tes découvertes commencent ici',
                  message:
                      'Lance une recherche dans Conseil. Tu retrouveras ici ta demande et tous les titres proposés.',
                ),
              if (loaded && runs.isNotEmpty && filtered.isEmpty)
                const _EmptyHistory(
                  icon: Icons.search_off_rounded,
                  title: 'Aucune recherche trouvée',
                  message:
                      'Essaie un autre titre ou quelques mots de ta demande.',
                ),
              for (final group in groups.entries) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(0, 20, 0, 10),
                  child: Text(
                    group.key,
                    style: const TextStyle(
                      color: _muted,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                for (final run in group.value)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _RequestCard(
                      key: ValueKey(run['id']),
                      run: run,
                      cover: _cover,
                      onOpen: () => _open(run),
                      onSelect: (index) => _open(run, index),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyHistory extends StatelessWidget {
  final IconData icon;
  final String title, message;
  const _EmptyHistory({
    required this.icon,
    required this.title,
    required this.message,
  });
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 12),
    child: Column(
      children: [
        Icon(icon, color: _accent, size: 30),
        const SizedBox(height: 14),
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontFamily: 'serif',
            color: _ink,
            fontSize: 22,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(color: _muted, fontSize: 13, height: 1.5),
        ),
      ],
    ),
  );
}

class _RequestCard extends StatelessWidget {
  final Map run;
  final Future<String?> Function(List) cover;
  final VoidCallback onOpen;
  final ValueChanged<int> onSelect;
  const _RequestCard({
    super.key,
    required this.run,
    required this.cover,
    required this.onOpen,
    required this.onSelect,
  });
  @override
  Widget build(BuildContext context) {
    final recs = historyRecommendations(run);
    final time = _time(_created(run));
    final count = recs.isEmpty
        ? _outcome(run)
        : '${recs.length} proposition${recs.length > 1 ? 's' : ''}';
    return Material(
      color: const Color(0xfffffdf8),
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: _line),
        borderRadius: BorderRadius.circular(14),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: onOpen,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${run['prompt'] ?? 'Demande de lecture'}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: _ink,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            height: 1.35,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          [if (time.isNotEmpty) time, count].join(' · '),
                          style: const TextStyle(fontSize: 11, color: _muted),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Icon(
                    Icons.chevron_right_rounded,
                    color: _muted,
                    size: 20,
                  ),
                ],
              ),
            ),
          ),
          if (recs.isNotEmpty) ...[
            const Divider(height: 1, color: _line, indent: 14, endIndent: 14),
            const SizedBox(height: 4),
            for (var index = 0; index < recs.length; index++)
              InkWell(
                onTap: () => onSelect(index),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 5,
                  ),
                  child: Row(
                    children: [
                      _HistoryCover(
                        cover: cover(recs[index]['work']['sources'] ?? []),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '${recs[index]['work']['title'] ?? 'Titre inconnu'}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: _ink,
                            fontSize: 13,
                            height: 1.3,
                          ),
                        ),
                      ),
                      if (recs[index]['fit'] == 'exploratory')
                        const Padding(
                          padding: EdgeInsets.only(left: 6),
                          child: Tooltip(
                            message: 'Piste exploratoire',
                            child: Icon(
                              Icons.explore_outlined,
                              color: _accent,
                              size: 16,
                            ),
                          ),
                        ),
                      const SizedBox(width: 6),
                      const Icon(
                        Icons.chevron_right_rounded,
                        color: _muted,
                        size: 16,
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 4),
          ] else if (run['error'] != null || run['result']?['message'] != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
              child: Text(
                '${run['error'] ?? run['result']['message']}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: _muted,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _HistoryCover extends StatelessWidget {
  final Future<String?> cover;
  const _HistoryCover({required this.cover});

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        width: 30,
        height: 42,
        child: FutureBuilder<String?>(
          future: cover,
          builder: (_, snapshot) => snapshot.data == null
              ? _placeholder()
              : Image.network(
                  snapshot.data!,
                  width: 30,
                  height: 42,
                  fit: BoxFit.cover,
                  cacheWidth: 120,
                  frameBuilder: (_, child, frame, synchronouslyLoaded) =>
                      frame == null ? _placeholder() : child,
                  errorBuilder: (_, error, trace) => _placeholder(),
                ),
        ),
      ),
    ),
  );

  Widget _placeholder() => const ColoredBox(
    color: _tint,
    child: Center(
      child: Icon(Icons.menu_book_outlined, size: 16, color: _muted),
    ),
  );
}

class _HistoryRequestPage extends StatefulWidget {
  final Map run;
  final int? selectedIndex;
  final Future<String?> Function(List) cover;
  final Widget Function(Map)? recommendationActions;
  const _HistoryRequestPage({
    required this.run,
    required this.cover,
    this.recommendationActions,
    this.selectedIndex,
  });
  @override
  State<_HistoryRequestPage> createState() => _HistoryRequestPageState();
}

class _HistoryRequestPageState extends State<_HistoryRequestPage> {
  final selectedKey = GlobalKey();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = selectedKey.currentContext;
      if (mounted && context != null) {
        Scrollable.ensureVisible(context, alignment: .1);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final run = widget.run;
    final result = run['result'] is Map
        ? run['result'] as Map
        : <String, dynamic>{};
    final recs = historyRecommendations(run);
    final filters = [
      for (final value in run['filters'] ?? []) adviceFilterLabel('$value'),
      if (run['mode'] == 'absolute') 'Demande à la lettre',
    ];
    final scope = switch (run['scope']) {
      'backlog' => 'Dans la pile À lire',
      'resume' => 'Lectures à reprendre',
      'unread' => 'Nouveautés et pile À lire',
      _ => 'Hors de la bibliothèque',
    };
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xfffaf8f2),
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Recherche enregistrée',
              style: TextStyle(fontSize: 11, color: _muted),
            ),
            const SizedBox(height: 2),
            Text(
              '${run['prompt'] ?? 'Demande de lecture'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 15,
                color: _ink,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '${run['prompt'] ?? 'Demande de lecture'}',
                  style: const TextStyle(
                    fontFamily: 'serif',
                    fontSize: 26,
                    height: 1.2,
                    color: _ink,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  [
                    _date(_created(run)),
                    _time(_created(run)),
                  ].where((s) => s.isNotEmpty).join(' · '),
                  style: const TextStyle(fontSize: 12, color: _muted),
                ),
                const SizedBox(height: 5),
                Text(
                  scope,
                  style: const TextStyle(fontSize: 12, color: _muted),
                ),
                if (filters.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final filter in filters)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              color: _tint,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              filter,
                              style: const TextStyle(
                                fontSize: 11,
                                color: _accent,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                if (result['message'] != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 18),
                    child: Text(
                      '${result['message']}',
                      style: const TextStyle(
                        fontSize: 14,
                        height: 1.5,
                        color: _ink,
                      ),
                    ),
                  ),
                for (final note in result['reservations'] ?? [])
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      '$note',
                      style: const TextStyle(
                        fontSize: 12,
                        height: 1.4,
                        color: _muted,
                      ),
                    ),
                  ),
                const SizedBox(height: 20),
                Text(
                  recs.isEmpty
                      ? _outcome(run)
                      : '${recs.length} lecture${recs.length > 1 ? 's' : ''} proposée${recs.length > 1 ? 's' : ''}',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: _ink,
                  ),
                ),
                if (run['error'] != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      '${run['error']}',
                      style: const TextStyle(
                        color: _muted,
                        fontSize: 13,
                        height: 1.5,
                      ),
                    ),
                  ),
                for (var index = 0; index < recs.length; index++)
                  Padding(
                    key: index == widget.selectedIndex ? selectedKey : null,
                    padding: const EdgeInsets.only(top: 10),
                    child: _RecommendationDetail(
                      rec: recs[index],
                      index: index,
                      initiallyExpanded: index == widget.selectedIndex,
                      cover: widget.cover,
                      recommendationActions: widget.recommendationActions,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RecommendationDetail extends StatefulWidget {
  final Map rec;
  final int index;
  final bool initiallyExpanded;
  final Future<String?> Function(List) cover;
  final Widget Function(Map)? recommendationActions;
  const _RecommendationDetail({
    required this.rec,
    required this.index,
    required this.initiallyExpanded,
    required this.cover,
    this.recommendationActions,
  });
  @override
  State<_RecommendationDetail> createState() => _RecommendationDetailState();
}

class _RecommendationDetailState extends State<_RecommendationDetail> {
  Future<String?>? cover;
  @override
  void initState() {
    super.initState();
    if (widget.initiallyExpanded) _loadCover();
  }

  void _loadCover() {
    cover ??= widget.cover(widget.rec['work']['sources'] ?? []);
  }

  @override
  Widget build(BuildContext context) {
    final rec = widget.rec;
    return Material(
      color: const Color(0xfffffdf8),
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: _line),
        borderRadius: BorderRadius.circular(14),
      ),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        initiallyExpanded: widget.initiallyExpanded,
        onExpansionChanged: (open) {
          if (open) setState(_loadCover);
        },
        tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 16),
        shape: const Border(),
        collapsedShape: const Border(),
        title: RecommendationTitle(
          '${rec['work']['title']}',
          style: const TextStyle(
            fontSize: 15,
            color: _ink,
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Text(
          'Proposition ${widget.index + 1}${rec['fit'] == 'exploratory' ? ' · Piste exploratoire' : ''}',
          style: const TextStyle(fontSize: 11, color: _muted),
        ),
        children: [
          if (widget.recommendationActions != null)
            widget.recommendationActions!(rec['work'] as Map),
          if (cover != null)
            FutureBuilder<String?>(
              future: cover,
              builder: (_, snapshot) => snapshot.data == null
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(5),
                          child: Image.network(
                            snapshot.data!,
                            height: 110,
                            errorBuilder: (_, error, trace) =>
                                const SizedBox.shrink(),
                          ),
                        ),
                      ),
                    ),
            ),
          if (rec['why_this'] != null)
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '${rec['why_this']}',
                style: const TextStyle(color: _ink, fontSize: 14, height: 1.5),
              ),
            ),
          if (rec['fit'] == 'exploratory' && rec['exploration_reason'] != null)
            _note('Piste exploratoire', '${rec['exploration_reason']}'),
          for (final note in rec['reservations'] ?? [])
            _note('À savoir', '$note'),
          for (final basis in rec['personal_basis'] ?? [])
            if (basis is Map && basis['explanation'] != null)
              _note('Ce qui rejoint tes goûts', '${basis['explanation']}'),
          if ((rec['work']['sources'] as List? ?? []).isNotEmpty)
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text(
                'Sources',
                style: TextStyle(color: _muted, fontSize: 12),
              ),
              shape: const Border(),
              collapsedShape: const Border(),
              children: [
                for (final source in rec['work']['sources'])
                  if (source['url'] != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: SelectableText(
                          '${source['url']}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: _muted,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _note(String label, String message) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              color: _accent,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            message,
            style: const TextStyle(fontSize: 13, color: _muted, height: 1.5),
          ),
        ],
      ),
    ),
  );
}
