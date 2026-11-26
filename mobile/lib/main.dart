import 'package:flutter/material.dart';
import 'advice.dart';
import 'library.dart';
import 'history.dart';
import 'reading_links.dart';
import 'engine.dart';
import 'sync.dart';
import 'settings.dart';
import 'mangatime.dart';
import 'updates.dart';
import 'recommendation_title.dart';

void main() => runApp(const ReadingApp());

class ReadingApp extends StatelessWidget {
  const ReadingApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Iris',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff8d392c),
        primary: const Color(0xff8d392c),
      ),
      scaffoldBackgroundColor: const Color(0xfffaf8f2),
    ),
    home: const Notebook(),
  );
}

class Notebook extends StatefulWidget {
  const Notebook({super.key});
  @override
  State<Notebook> createState() => _NotebookState();
}

class _NotebookState extends State<Notebook> with WidgetsBindingObserver {
  int selected = 0;
  final sync = MangaSync();
  final server = IrisEngine();
  bool loading = false;
  int historyRevision = 0;
  @override
  void initState() {
    super.initState();
    sync.addListener(changed);
    sync.start();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) IrisUpdates.check(context, automatic: true);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted && !loading) {
      IrisUpdates.check(context, automatic: true);
    }
  }

  void changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    sync.dispose();
    WidgetsBinding.instance.removeObserver(this);
    server.close();
    super.dispose();
  }

  Future<void> preview(Map<String, dynamic> request) async {
    FocusManager.instance.primaryFocus?.unfocus();
    if (loading) return;
    setState(() => loading = true);
    try {
      if (!await server.configured()) {
        if (!mounted) return;
        await settings();
        if (!await server.configured()) return;
      }
      await sync.refresh();
      if (sync.error != null) throw FormatException(sync.error!);
      final result = await server.advise({
        ...request,
        if (sync.rows != null) 'library': sync.rows,
      });
      if (!mounted) return;
      await showAdvice(result);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              e is FormatException
                  ? e.message
                  : 'Recherche indisponible. Vérifie ta connexion Internet et réessaie.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          loading = false;
          historyRevision++;
        });
      }
    }
  }

  Future<void> settings() => Navigator.of(
    context,
  ).push<void>(MaterialPageRoute(builder: (_) => SettingsPage(server)));

  Widget mangaTimeAction(Map work) => MangaTimeButton(
    engine: server,
    work: work,
    onChanged: () => sync.refresh(),
  );

  Future<void> showAdvice(Map result) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: FractionallySizedBox(
        heightFactor: .8,
        child: ScaffoldMessenger(
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                heading('Conseil de lecture'),
                Text(result['message'] ?? ''),
                for (final r in result['reservations'] ?? []) Text(r),
                for (final rec
                    in result['recommendations'] ??
                        (result['work'] == null ? [] : [result])) ...[
                  const Divider(),
                  RecommendationTitle(rec['work']['title'] as String),
                  mangaTimeAction(rec['work'] as Map),
                  FutureBuilder<String?>(
                    future: server.cover(rec['work']['sources'] ?? []),
                    builder: (context, s) => s.data == null
                        ? const SizedBox.shrink()
                        : Align(
                            alignment: Alignment.centerLeft,
                            child: Image.network(
                              s.data!,
                              height: 145,
                              errorBuilder: (_, e, st) =>
                                  const SizedBox.shrink(),
                            ),
                          ),
                  ),
                  if (rec['fit'] == 'exploratory')
                    Text('Piste exploratoire · ${rec['exploration_reason']}'),
                  Text(rec['why_this'] ?? ''),
                  for (final note in rec['reservations'] ?? []) Text(note),
                ],
              ],
            ),
          ),
        ),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      actions: [
        IconButton(
          tooltip: 'Réglages',
          onPressed: settings,
          icon: const Icon(Icons.tune),
        ),
      ],
      title: Row(
        children: [
          Image.asset(
            'assets/iris-logo.png',
            width: 34,
            height: 34,
            excludeFromSemantics: true,
          ),
          const SizedBox(width: 8),
          const Text('Iris', style: TextStyle(fontFamily: 'serif')),
        ],
      ),
    ),
    body: SafeArea(
      top: false,
      child: IndexedStack(
        index: selected,
        children: [
          AdvicePage(loading: loading, onSearch: preview),
          HistoryPage(
            active: selected == 1,
            revision: historyRevision,
            load: () async => await server.request('history') as List,
            cover: server.cover,
            recommendationActions: mangaTimeAction,
          ),
          ReadingLinksPage(
            server,
            active: selected == 2,
            revision: historyRevision,
            library: sync.rows,
          ),
          LibraryPage(sync),
        ],
      ),
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: selected,
      onDestinationSelected: (i) {
        FocusManager.instance.primaryFocus?.unfocus();
        setState(() => selected = i);
      },
      destinations: const [
        NavigationDestination(icon: Icon(Icons.menu_book), label: 'Conseil'),
        NavigationDestination(icon: Icon(Icons.history), label: 'Historique'),
        NavigationDestination(
          icon: Icon(Icons.travel_explore),
          label: 'Où lire',
        ),
        NavigationDestination(
          icon: Icon(Icons.library_books_outlined),
          label: 'Bibliothèque',
        ),
      ],
    ),
  );
}

Widget heading(String text) => Text(
  text,
  style: const TextStyle(fontFamily: 'serif', fontSize: 28, height: 1.15),
);
