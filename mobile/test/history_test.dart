import 'dart:async';
import 'package:entre_les_lignes/history.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> recommendation(String title) => {
  'work': {'title': title, 'sources': <Map>[]},
  'why_this': 'Le conseil pour $title.',
  'reservations': ['Une réserve pour $title.'],
  'personal_basis': [
    {'explanation': 'Un rapprochement pour $title.'},
  ],
  'fit': 'strong',
};

Map<String, dynamic> run(
  String id,
  String prompt,
  List<String> titles, {
  DateTime? date,
}) => {
  'id': id,
  'prompt': prompt,
  'created': (date ?? DateTime.now()).millisecondsSinceEpoch / 1000,
  'status': 'done',
  'scope': 'discovery',
  'filters': ['finished', 'genre:romance'],
  'mode': 'absolute',
  'result': {
    'status': 'recommendation',
    'message': 'Le bilan de $prompt.',
    'recommendations': titles.map(recommendation).toList(),
  },
};

void main() {
  Future<void> mount(
    WidgetTester tester,
    Future<List<dynamic>> Function() load, {
    Size size = const Size(390, 844),
    double scale = 1,
    Future<String?> Function(List)? cover,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(colorSchemeSeed: const Color(0xff8d392c)),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: HistoryPage(load: load, cover: cover ?? (_) async => null),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'Chaque requête garde sa liste, même pour deux demandes identiques',
    (tester) async {
      await mount(
        tester,
        () async => [
          run(
            'older',
            'Romance GL vampire',
            ['Ancienne piste'],
            date: DateTime.now().subtract(const Duration(hours: 1)),
          ),
          run('newer', 'Romance GL vampire', [
            'Premier titre',
            'Deuxième titre',
          ]),
        ],
      );
      await tester.pumpAndSettle();
      expect(find.text('Romance GL vampire'), findsNWidgets(2));
      expect(find.text('Premier titre'), findsOneWidget);
      expect(find.text('Deuxième titre'), findsOneWidget);
      expect(find.text('Ancienne piste'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Premier titre')).dy,
        lessThan(tester.getTopLeft(find.text('Ancienne piste')).dy),
      );
      expect(find.text('2 recherches · 3 propositions'), findsOneWidget);
    },
  );

  testWidgets(
    'Rechercher un titre retrouve sa requête et les titres associés',
    (tester) async {
      await mount(
        tester,
        () async => [
          run('1', 'Une romance', ['Étoile rouge', 'Lune bleue']),
          run('2', 'Une aventure', ['Le voyage']),
        ],
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'etoile');
      await tester.pumpAndSettle();
      expect(find.text('Une romance'), findsOneWidget);
      expect(find.text('Lune bleue'), findsOneWidget);
      expect(find.text('Une aventure'), findsNothing);
      await tester.enterText(find.byType(TextField), 'inexistant');
      await tester.pumpAndSettle();
      expect(find.text('Aucune recherche trouvée'), findsOneWidget);
      await tap(tester, find.byTooltip('Effacer la recherche'));
      expect(find.text('Une aventure'), findsOneWidget);
    },
  );

  testWidgets('Un titre ouvre le bon conseil et les réglages de sa requête', (
    tester,
  ) async {
    var covers = 0;
    final saved = run('1', 'Une romance', ['Premier titre', 'Deuxième titre']);
    final recs = saved['result']['recommendations'] as List;
    for (var index = 0; index < recs.length; index++) {
      recs[index]['work']['sources'] = [
        {'id': 'anilist:${index + 1}'},
      ];
    }
    await mount(
      tester,
      () async => [saved],
      cover: (_) async {
        covers++;
        return null;
      },
    );
    await tester.pumpAndSettle();
    expect(covers, 2);
    expect(find.text('1'), findsNothing);
    expect(find.text('2'), findsNothing);
    await tap(tester, find.text('Deuxième titre'));
    expect(find.text('Recherche enregistrée'), findsOneWidget);
    expect(find.text('Le conseil pour Deuxième titre.'), findsOneWidget);
    expect(find.text('Le conseil pour Premier titre.'), findsNothing);
    expect(find.text('Publication terminée'), findsOneWidget);
    expect(find.text('Demande à la lettre'), findsOneWidget);
    expect(covers, 2);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Une romance'), findsOneWidget);
    expect(find.text('Deuxième titre'), findsOneWidget);
    expect(covers, 2);
  });

  testWidgets('Les anciens conseils à une œuvre restent consultables', (
    tester,
  ) async {
    final legacy = run('legacy', 'Ancienne demande', []);
    legacy['result'] = {
      'status': 'recommendation',
      ...recommendation('Ancien titre'),
    };
    await mount(tester, () async => [legacy]);
    await tester.pumpAndSettle();
    await tap(tester, find.text('Ancien titre'));
    expect(find.text('Le conseil pour Ancien titre.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Le chargement et la liste vide ont un état explicite', (
    tester,
  ) async {
    final pending = Completer<List<dynamic>>();
    await mount(tester, () => pending.future);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('Tes découvertes commencent ici'), findsNothing);
    pending.complete([]);
    await tester.pumpAndSettle();
    expect(find.text('Tes découvertes commencent ici'), findsOneWidget);
  });

  testWidgets('Le premier chargement en erreur peut être relancé', (
    tester,
  ) async {
    var calls = 0;
    await mount(tester, () async {
      if (++calls == 1) throw StateError('offline');
      return [];
    });
    await tester.pumpAndSettle();
    expect(find.text('Réessayer'), findsOneWidget);
    expect(find.text('Tes découvertes commencent ici'), findsNothing);
    await tap(tester, find.text('Réessayer'));
    expect(find.text('Tes découvertes commencent ici'), findsOneWidget);
  });

  testWidgets('Une nouvelle recherche actualise un historique déjà ouvert', (
    tester,
  ) async {
    final revision = ValueNotifier(0);
    addTearDown(revision.dispose);
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<int>(
            valueListenable: revision,
            builder: (_, value, child) => HistoryPage(
              revision: value,
              cover: (_) async => null,
              load: () async {
                calls++;
                return [
                  run('1', 'Demande initiale', ['Premier conseil']),
                  if (value > 0)
                    run('2', 'Nouvelle demande', ['Nouveau conseil']),
                ];
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Nouveau conseil'), findsNothing);
    revision.value++;
    await tester.pumpAndSettle();
    expect(find.text('Nouveau conseil'), findsOneWidget);
    expect(calls, 2);
  });

  testWidgets(
    'Une erreur de rafraîchissement conserve les recherches chargées',
    (tester) async {
      var calls = 0;
      await mount(tester, () async {
        if (++calls == 2) throw StateError('offline');
        return [
          run('1', 'Une romance', ['Titre conservé']),
        ];
      });
      await tester.pumpAndSettle();
      await tap(tester, find.byTooltip('Actualiser l’historique'));
      expect(find.text('Titre conservé'), findsOneWidget);
      expect(
        find.text('Les recherches déjà chargées restent disponibles.'),
        findsOneWidget,
      );
      await tap(tester, find.text('Réessayer'));
      expect(find.text('Réessayer'), findsNothing);
      expect(calls, 3);
    },
  );

  testWidgets(
    'Les recherches sans résultat ou interrompues ne disparaissent pas',
    (tester) async {
      await mount(
        tester,
        () async => [
          {
            ...run('1', 'Demande sans résultat', []),
            'result': {
              'status': 'abstention',
              'message': 'Aucun titre confirmé.',
            },
          },
          {
            ...run('2', 'Demande interrompue', []),
            'status': 'error',
            'error': 'Catalogue indisponible.',
            'result': null,
          },
        ],
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Aucune proposition'), findsOneWidget);
      expect(find.textContaining('Recherche interrompue'), findsOneWidget);
      await tap(tester, find.text('Demande interrompue'));
      expect(find.text('Catalogue indisponible.'), findsOneWidget);
    },
  );

  for (final config in [
    (size: const Size(320, 640), scale: 1.0),
    (size: const Size(390, 844), scale: 2.0),
    (size: const Size(844, 390), scale: 1.0),
  ]) {
    testWidgets(
      'Liste et détails sans débordement à ${config.size}, texte ${config.scale}',
      (tester) async {
        final title =
            'Un titre particulièrement long qui doit rester lisible sur un petit écran';
        await mount(
          tester,
          () async => [
            run(
              '1',
              'Une demande très détaillée pour une romance dans un univers fantastique avec des vampires',
              [title, 'Autre titre'],
            ),
          ],
          size: config.size,
          scale: config.scale,
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tap(tester, find.text(title));
        expect(find.text('Le conseil pour $title.'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
