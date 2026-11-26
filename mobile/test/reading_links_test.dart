import 'package:entre_les_lignes/reading_links.dart';
import 'package:entre_les_lignes/engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class SuggestionServer extends IrisEngine {
  final paths = <String>[];
  bool offline = false;
  List<Map> matches = [];
  Map chapterResult = {
    'requested': ['41'],
    'warnings': [],
    'chapters': [],
  };
  @override
  Future<dynamic> request(
    String path, {
    Map? body,
    String? token,
    Duration responseTimeout = const Duration(seconds: 20),
  }) async {
    paths.add(path);
    if (path == 'history') {
      if (offline) throw const FormatException('Serveur indisponible');
      return [
        {
          'status': 'done',
          'created': 1,
          'result': {
            'recommendations': [
              {
                'work': {'title': 'Kiss the Scars of the Girls', 'sources': []},
              },
            ],
          },
        },
      ];
    }
    if (path.startsWith('reading/search?')) return {'works': matches};
    if (path.startsWith('reading/chapters?')) return chapterResult;
    throw StateError('Appel inattendu : $path');
  }
}

void main() {
  Future<SuggestionServer> mount(
    WidgetTester tester, {
    bool offline = false,
    Size size = const Size(390, 844),
    double scale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final server = SuggestionServer()..offline = offline;
    addTearDown(server.close);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: ReadingLinksPage(
            server,
            library: [
              {'titre': 'Solo Leveling'},
              {'titre': 'La Fiancée de la Vilaine'},
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return server;
  }

  testWidgets(
    'Conseils et bibliothèque sont suggérés, un choix remplit le titre',
    (tester) async {
      final server = await mount(tester);
      final fields = find.byType(TextField);
      await tester.tap(fields.first);
      await tester.pumpAndSettle();
      expect(find.text('Proposé dans tes conseils'), findsOneWidget);
      expect(find.text('Solo Leveling'), findsOneWidget);
      await tester.enterText(fields.first, 'kiss');
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(ListTile, 'Kiss the Scars of the Girls'),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(fields.first).controller!.text,
        'Kiss the Scars of the Girls',
      );
      expect(tester.widget<TextField>(fields.last).focusNode!.hasFocus, isTrue);
      expect(find.byType(ListTile), findsNothing);
      expect(server.paths, ['history']);
    },
  );

  testWidgets('Le choix garde le chapitre et attend le bouton pour chercher', (
    tester,
  ) async {
    final server = await mount(tester);
    final fields = find.byType(TextField);
    await tester.enterText(fields.last, '41');
    await tester.enterText(fields.first, 'solo');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Solo Leveling'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(fields.first).controller!.text,
      'Solo Leveling',
    );
    expect(tester.widget<TextField>(fields.last).controller!.text, '41');
    expect(server.paths, ['history']);
    await tester.ensureVisible(find.text('Trouver les chapitres'));
    await tester.tap(find.text('Trouver les chapitres'));
    await tester.pumpAndSettle();
    expect(server.paths.last, 'reading/search?title=Solo+Leveling');
  });

  testWidgets(
    'Une œuvre unique enchaîne directement sur les chapitres et une seule liste',
    (tester) async {
      final server = await mount(tester);
      server.matches = [
        {'id': 'unique', 'title': 'Solo Leveling', 'subtitle': ''},
      ];
      server.chapterResult = {
        'requested': ['41', '42'],
        'warnings': [],
        'official': [
          {'url': 'https://publisher.example/series', 'site': 'Page de série'},
        ],
        'independent': [
          {'url': 'https://other.example/series', 'site': 'Autre fiche'},
        ],
        'chapters': [
          {
            'chapter': '41',
            'language': 'fr',
            'site': 'MangaDex',
            'url': 'https://mangadex.org/chapter/41',
            'verified': true,
            'access': 'reader',
          },
          {
            'chapter': '41',
            'language': 'en',
            'site': 'publisher.example',
            'url': 'https://publisher.example/chapter/41',
            'verified': true,
            'access': 'purchase',
          },
          {
            'chapter': '42',
            'language': 'en',
            'site': 'Non confirmé',
            'url': 'https://other.example/42',
          },
        ],
      };
      final fields = find.byType(TextField);
      await tester.enterText(fields.first, 'Solo Leveling');
      await tester.enterText(fields.last, '41-42');
      await tester.tap(find.text('Trouver les chapitres'));
      await tester.pumpAndSettle();
      expect(server.paths.last, 'reading/chapters?id=unique&chapters=41-42');
      expect(find.text('Choisis la bonne œuvre.'), findsNothing);
      expect(find.text('Chapitres disponibles'), findsOneWidget);
      expect(find.text('Chapitre 41 · Français'), findsOneWidget);
      expect(find.text('Chapitre 41 · Anglais'), findsOneWidget);
      expect(find.text('Non confirmé'), findsNothing);
      expect(find.text('Page de série'), findsNothing);
      expect(find.text('Autre fiche'), findsNothing);
      expect(
        find.text('Aucun lien confirmé pour le chapitre 42.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'Plusieurs œuvres demandent un choix avant de chercher leurs chapitres',
    (tester) async {
      final server = await mount(tester);
      server.matches = [
        {'id': 'first', 'title': 'Premier homonyme', 'subtitle': ''},
        {'id': 'second', 'title': 'Deuxième homonyme', 'subtitle': ''},
      ];
      await tester.enterText(find.byType(TextField).first, 'Homonyme');
      await tester.enterText(find.byType(TextField).last, '41');
      await tester.tap(find.text('Trouver les chapitres'));
      await tester.pumpAndSettle();
      expect(find.text('Choisis la bonne œuvre.'), findsOneWidget);
      expect(
        server.paths.where((path) => path.startsWith('reading/chapters')),
        isEmpty,
      );
      await tester.tap(find.text('Deuxième homonyme'));
      await tester.pumpAndSettle();
      expect(server.paths.last, 'reading/chapters?id=second&chapters=41');
    },
  );

  testWidgets('Un chapitre est nécessaire avant tout appel de recherche', (
    tester,
  ) async {
    final server = await mount(tester);
    await tester.enterText(find.byType(TextField).first, 'Solo Leveling');
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(server.paths, ['history']);
    expect(
      find.text('Indique le chapitre ou la plage à rechercher.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'La bibliothèque reste disponible hors ligne et la saisie reste libre',
    (tester) async {
      await mount(tester, offline: true);
      final field = find.byType(TextField).first;
      await tester.enterText(field, 'fiancee');
      await tester.pumpAndSettle();
      expect(find.text('La Fiancée de la Vilaine'), findsOneWidget);
      await tester.enterText(field, 'Un titre jamais vu');
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(field).controller!.text,
        'Un titre jamais vu',
      );
      expect(find.byType(ListTile), findsNothing);
      expect(find.text('Serveur indisponible'), findsNothing);
    },
  );

  for (final config in [
    (size: const Size(320, 640), scale: 1.0),
    (size: const Size(390, 844), scale: 2.0),
  ]) {
    testWidgets('Suggestions à ${config.size}, texte ${config.scale}', (
      tester,
    ) async {
      await mount(tester, size: config.size, scale: config.scale);
      await tester.enterText(find.byType(TextField).first, 'kiss');
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(ListTile, 'Kiss the Scars of the Girls'),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
