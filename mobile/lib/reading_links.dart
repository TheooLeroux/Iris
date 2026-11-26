import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'engine.dart';
import 'reading_titles.dart';

class ReadingLinksPage extends StatefulWidget {
  const ReadingLinksPage(
    this.server, {
    super.key,
    this.active = true,
    this.revision = 0,
    this.library,
  });
  final IrisEngine server;
  final bool active;
  final int revision;
  final List<dynamic>? library;

  @override
  State<ReadingLinksPage> createState() => _ReadingLinksPageState();
}

class _ReadingLinksPageState extends State<ReadingLinksPage> {
  final title = TextEditingController();
  final chapters = TextEditingController();
  final titleFocus = FocusNode();
  final chaptersFocus = FocusNode();
  List<dynamic> savedRuns = [], fallbackLibrary = [];
  bool loadingTitles = false;
  String previousTitle = '';
  String previousChapters = '';
  List<dynamic> works = [];
  Map<String, dynamic>? results;
  String? error;
  String? selectedTitle;
  bool busy = false;
  bool searched = false;
  String step = '';

  @override
  void initState() {
    super.initState();
    title.addListener(_titleChanged);
    chapters.addListener(_chaptersChanged);
    titleFocus.addListener(_focusChanged);
    _loadLibrary();
    if (widget.active) _loadHistory();
  }

  @override
  void didUpdateWidget(covariant ReadingLinksPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active &&
        (!oldWidget.active || widget.revision != oldWidget.revision)) {
      _loadHistory();
    }
  }

  Future<void> _loadLibrary() async {
    if (widget.library != null) return;
    try {
      final rows = await widget.server.request('mangatime/library') as List;
      if (mounted) setState(() => fallbackLibrary = rows);
    } catch (_) {
      // A synchronized library can still provide suggestions.
    }
  }

  Future<void> _loadHistory() async {
    if (loadingTitles) return;
    loadingTitles = true;
    try {
      final rows = await widget.server.request('history') as List;
      if (mounted) setState(() => savedRuns = rows);
    } catch (_) {
      // Keep library suggestions and any previously loaded recommendations.
    } finally {
      if (mounted) setState(() => loadingTitles = false);
    }
  }

  void _focusChanged() {
    if (mounted) setState(() {});
  }

  void _titleChanged() {
    if (!mounted || title.text == previousTitle) return;
    setState(() {
      previousTitle = title.text;
      works = [];
      results = null;
      searched = false;
      selectedTitle = null;
      error = null;
    });
  }

  void _selectTitle(ReadingTitle suggestion) {
    title.value = TextEditingValue(
      text: suggestion.title,
      selection: TextSelection.collapsed(offset: suggestion.title.length),
    );
    chaptersFocus.requestFocus();
  }

  void _chaptersChanged() {
    if (!mounted || chapters.text == previousChapters) return;
    setState(() {
      previousChapters = chapters.text;
      results = null;
      error = null;
    });
  }

  @override
  void dispose() {
    title.removeListener(_titleChanged);
    chapters.removeListener(_chaptersChanged);
    titleFocus.removeListener(_focusChanged);
    titleFocus.dispose();
    chaptersFocus.dispose();
    title.dispose();
    chapters.dispose();
    super.dispose();
  }

  Future<void> search([Map? work]) async {
    if (busy) return;
    if (work == null && title.text.trim().isEmpty) {
      setState(() => error = 'Indique le titre de l’œuvre.');
      titleFocus.requestFocus();
      return;
    }
    if (chapters.text.trim().isEmpty) {
      setState(() => error = 'Indique le chapitre ou la plage à rechercher.');
      chaptersFocus.requestFocus();
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      busy = true;
      error = null;
      results = null;
      step = work == null
          ? 'Recherche de l’œuvre…'
          : 'Vérification des chapitres…';
      if (work == null) {
        works = [];
        selectedTitle = null;
        searched = false;
      }
    });
    try {
      Map? target = work;
      if (target == null) {
        final response = await widget.server.request(
          'reading/search?title=${Uri.encodeQueryComponent(title.text.trim())}',
        );
        if (!mounted) return;
        final matches = response['works'] as List;
        setState(() {
          works = matches;
          searched = true;
        });
        if (matches.length != 1) return;
        target = matches.single as Map;
      }
      setState(() {
        works = [];
        selectedTitle = target!['title'];
        step = 'Vérification des chapitres…';
      });
      final response = await widget.server.request(
        'reading/chapters?id=${Uri.encodeQueryComponent(target['id'])}&chapters=${Uri.encodeQueryComponent(chapters.text.trim())}',
        responseTimeout: const Duration(seconds: 180),
      );
      if (!mounted) return;
      setState(() => results = Map<String, dynamic>.from(response as Map));
    } catch (failure) {
      if (!mounted) return;
      setState(
        () => error = failure is FormatException
            ? failure.message
            : 'Recherche indisponible. Vérifie ta connexion Internet.',
      );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> open(String url) async {
    try {
      await const MethodChannel(
        'iris/library',
      ).invokeMethod<void>('openLink', url);
    } on PlatformException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Impossible d’ouvrir le site.')),
      );
    }
  }

  String language(String code) =>
      const {
        'fr': 'Français',
        'en': 'Anglais',
        'ja': 'Japonais',
        'ko': 'Coréen',
        'zh': 'Chinois simplifié',
        'zh-hk': 'Chinois traditionnel',
        'es': 'Espagnol',
        'es-la': 'Espagnol latino-américain',
        'pt': 'Portugais',
        'pt-br': 'Portugais brésilien',
        'de': 'Allemand',
        'it': 'Italien',
        'pl': 'Polonais',
        'ru': 'Russe',
        'ar': 'Arabe',
        'id': 'Indonésien',
        'vi': 'Vietnamien',
        'th': 'Thaï',
        '?': 'Langue non renseignée',
      }[code.toLowerCase()] ??
      code;

  @override
  Widget build(BuildContext context) {
    final suggestions = titleFocus.hasFocus && !busy
        ? matchingReadingTitles(
            readingTitles(
              history: savedRuns,
              library: widget.library ?? fallbackLibrary,
            ),
            title.text,
          )
        : <ReadingTitle>[];
    final found = ((results?['chapters'] as List?) ?? [])
        .whereType<Map>()
        .where((row) => row['verified'] == true)
        .toList();
    int languageOrder(String code) => code == 'fr'
        ? 0
        : code == 'en'
        ? 1
        : 2;
    found.sort((a, b) {
      final chapter = (num.tryParse('${a['chapter']}') ?? 0).compareTo(
        num.tryParse('${b['chapter']}') ?? 0,
      );
      if (chapter != 0) return chapter;
      final order = languageOrder(
        '${a['language']}',
      ).compareTo(languageOrder('${b['language']}'));
      return order != 0
          ? order
          : language(
              '${a['language']}',
            ).compareTo(language('${b['language']}'));
    });
    final requested = (results?['requested'] as List?) ?? [];
    final missing = requested
        .where((number) => !found.any((row) => row['chapter'] == number))
        .toList();
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          'Où lire ?',
          style: TextStyle(fontFamily: 'serif', fontSize: 28),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: title,
          focusNode: titleFocus,
          enabled: !busy,
          textInputAction: TextInputAction.next,
          onSubmitted: (_) => chaptersFocus.requestFocus(),
          decoration: const InputDecoration(
            labelText: 'Titre ou titre alternatif',
            hintText: 'Tes conseils et ta bibliothèque',
            border: OutlineInputBorder(),
          ),
        ),
        if (suggestions.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: TextFieldTapRegion(
              child: Material(
                color: const Color(0xfffffdf8),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: const BorderSide(color: Color(0xffe5ded3)),
                ),
                clipBehavior: Clip.antiAlias,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 200),
                  child: ListView.builder(
                    primary: false,
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: suggestions.length,
                    itemBuilder: (context, index) {
                      final suggestion = suggestions[index];
                      return ListTile(
                        dense: true,
                        visualDensity: VisualDensity.compact,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                        ),
                        leading: Icon(
                          suggestion.proposed
                              ? Icons.auto_stories_outlined
                              : Icons.library_books_outlined,
                          size: 20,
                          color: const Color(0xff8d392c),
                        ),
                        title: Text(
                          suggestion.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            color: Color(0xff302923),
                          ),
                        ),
                        subtitle: Text(
                          suggestion.source,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xff73675e),
                          ),
                        ),
                        onTap: () => _selectTitle(suggestion),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        const SizedBox(height: 10),
        TextField(
          controller: chapters,
          focusNode: chaptersFocus,
          enabled: !busy,
          decoration: const InputDecoration(
            labelText: 'Chapitre ou plage',
            hintText: '12, 12.5 ou 12-20',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 10),
        FilledButton(
          onPressed: busy ? null : () => search(),
          child: Text(busy ? step : 'Trouver les chapitres'),
        ),
        if (busy) const LinearProgressIndicator(),
        if (error != null)
          Padding(padding: const EdgeInsets.all(8), child: Text(error!)),
        if (searched &&
            works.isEmpty &&
            results == null &&
            selectedTitle == null &&
            !busy)
          const Text('Aucune œuvre trouvée. Essaie un autre titre.'),
        if (results == null && works.isNotEmpty) ...[
          const Text('Choisis la bonne œuvre.'),
          for (final work in works)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(work['title']),
              subtitle: Text(work['subtitle']),
              trailing: const Icon(Icons.chevron_right),
              onTap: busy ? null : () => search(work as Map),
            ),
        ],
        if (results != null) ...[
          const SizedBox(height: 16),
          Text(selectedTitle!, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            'Chapitres disponibles',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          Text(
            '${requested.length - missing.length}/${requested.length} chapitre${requested.length > 1 ? 's' : ''} confirmé${requested.length > 1 ? 's' : ''} · ${found.length} lien${found.length > 1 ? 's' : ''}',
            style: const TextStyle(fontSize: 12, color: Color(0xff73675e)),
          ),
          for (final warning in results!['warnings'] ?? [])
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '$warning',
                style: const TextStyle(fontSize: 12, color: Color(0xff73675e)),
              ),
            ),
          if (missing.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'Aucun lien confirmé pour ${missing.length == 1 ? 'le chapitre' : 'les chapitres'} ${missing.join(', ')}.',
                style: const TextStyle(fontSize: 13, height: 1.4),
              ),
            ),
          for (final row in found)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                'Chapitre ${row['chapter']} · ${language('${row['language']}')}',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: Text(
                '${row['site']}${row['access'] == 'purchase' ? ' · Achat du chapitre' : ''}',
                style: const TextStyle(fontSize: 12),
              ),
              trailing: const Icon(Icons.open_in_new_rounded, size: 20),
              onTap: () => open(row['url']),
            ),
        ],
      ],
    );
  }
}
