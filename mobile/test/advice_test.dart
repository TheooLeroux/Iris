import 'package:entre_les_lignes/advice.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> mount(
    WidgetTester tester, {
    Future<void> Function(Map<String, dynamic>)? onSearch,
    bool loading = false,
    Size size = const Size(390, 844),
    double scale = 1,
  }) async {
    tester.view.reset();
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
          body: AdvicePage(
            loading: loading,
            onSearch: onSearch ?? (_) async {},
          ),
        ),
      ),
    );
    if (!loading) await tester.pumpAndSettle();
  }

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    if (finder.evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        finder,
        150,
        scrollable: find.byType(Scrollable).last,
      );
    }
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('La demande par défaut conserve les paramètres du serveur', (
    tester,
  ) async {
    Map<String, dynamic>? sent;
    await mount(tester, onSearch: (request) async => sent = request);
    await tapVisible(tester, find.text('Trouver ma lecture'));
    expect(sent, {
      'prompt': 'Conseille-moi une lecture',
      'scope': 'discovery',
      'count': 5,
      'mode': 'guided',
      'filters': <String>[],
    });
  });

  testWidgets('Le nombre et les filtres appliqués sont transmis', (
    tester,
  ) async {
    Map<String, dynamic>? sent;
    await mount(tester, onSearch: (request) async => sent = request);
    await tester.enterText(
      find.byType(TextField),
      '  Une romance en fantasy  ',
    );
    await tapVisible(tester, find.byTooltip('Moins de propositions'));
    await tapVisible(tester, find.text('Affiner la recherche'));
    await tapVisible(tester, find.text('Manhwa · Corée'));
    await tapVisible(tester, find.text('Fantasy'));
    await tapVisible(tester, find.text('Romance'));
    await tapVisible(tester, find.text('Terminée'));
    await tapVisible(tester, find.text('Plus de 50 chapitres'));
    await tapVisible(tester, find.byType(Switch));
    await tapVisible(tester, find.text('Appliquer les filtres'));
    expect(find.text('6 réglages actifs'), findsOneWidget);
    await tapVisible(tester, find.text('Trouver ma lecture'));
    expect(sent, {
      'prompt': 'Une romance en fantasy',
      'scope': 'discovery',
      'count': 4,
      'mode': 'absolute',
      'filters': [
        'finished',
        'long',
        'country:KR',
        'genre:fantasy',
        'genre:romance',
      ],
    });
  });

  testWidgets(
    'Fermer annule les modifications, retirer et réinitialiser fonctionnent',
    (tester) async {
      Map<String, dynamic>? sent;
      await mount(tester, onSearch: (request) async => sent = request);
      await tapVisible(tester, find.text('Affiner la recherche'));
      await tapVisible(tester, find.text('Terminée'));
      await tapVisible(tester, find.byTooltip('Fermer sans appliquer'));
      expect(
        find.text('Genres, origine, publication, longueur'),
        findsOneWidget,
      );

      await tapVisible(tester, find.text('Affiner la recherche'));
      await tapVisible(tester, find.text('Terminée'));
      await tapVisible(tester, find.text('Plus de 50 chapitres'));
      await tapVisible(tester, find.text('Appliquer les filtres'));
      await tapVisible(
        tester,
        find.byTooltip('Retirer : Publication terminée'),
      );
      expect(find.text('1 réglage actif'), findsOneWidget);
      await tapVisible(tester, find.text('Trouver ma lecture'));
      expect(sent!['filters'], ['long']);

      await tapVisible(tester, find.text('Affiner la recherche'));
      await tapVisible(tester, find.text('Réinitialiser'));
      await tapVisible(tester, find.text('Appliquer les filtres'));
      await tapVisible(tester, find.text('Trouver ma lecture'));
      expect(sent!['filters'], isEmpty);
      expect(sent!['mode'], 'guided');
    },
  );

  testWidgets('Le nombre reste entre un et cinq', (tester) async {
    Map<String, dynamic>? sent;
    await mount(tester, onSearch: (request) async => sent = request);
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.add_rounded),
          )
          .onPressed,
      isNull,
    );
    for (var i = 0; i < 4; i++) {
      await tapVisible(tester, find.byTooltip('Moins de propositions'));
    }
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.remove_rounded),
          )
          .onPressed,
      isNull,
    );
    await tapVisible(tester, find.text('Trouver ma lecture'));
    expect(sent!['count'], 1);
    await tapVisible(tester, find.byTooltip('Plus de propositions'));
    await tapVisible(tester, find.text('Trouver ma lecture'));
    expect(sent!['count'], 2);
  });

  testWidgets(
    'Les options exclusives se remplacent et les nouveaux filtres se retirent',
    (tester) async {
      Map<String, dynamic>? sent;
      await mount(tester, onSearch: (request) async => sent = request);
      await tapVisible(tester, find.text('Affiner la recherche'));
      await tapVisible(tester, find.text('Manga · Japon'));
      await tapVisible(tester, find.text('Manhua · Chine'));
      await tapVisible(tester, find.text('Action'));
      await tapVisible(tester, find.text('Terminée'));
      await tapVisible(tester, find.text('En cours'));
      await tapVisible(tester, find.text('1 à 50 chapitres'));
      await tapVisible(tester, find.text('Plus de 100 chapitres'));
      await tapVisible(tester, find.text('Appliquer les filtres'));
      await tapVisible(tester, find.byTooltip('Retirer : Action'));
      await tapVisible(tester, find.text('Trouver ma lecture'));
      expect(sent!['filters'], ['ongoing', 'very_long', 'country:CN']);
      await tapVisible(tester, find.text('Affiner la recherche'));
      await tapVisible(tester, find.text('Réinitialiser'));
      await tapVisible(tester, find.text('Appliquer les filtres'));
      await tapVisible(tester, find.text('Trouver ma lecture'));
      expect(sent!['filters'], isEmpty);
    },
  );

  testWidgets('Le chargement bloque une seconde recherche et les réglages', (
    tester,
  ) async {
    await mount(tester, loading: true);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    expect(tester.widget<ListTile>(find.byType(ListTile)).onTap, isNull);
    await tester.scrollUntilVisible(
      find.byType(FilledButton),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    expect(find.text('Recherche en cours…'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final scenario in [
    (name: 'petit téléphone', size: const Size(320, 640), scale: 1.0),
    (name: 'texte agrandi', size: const Size(390, 844), scale: 2.0),
    (name: 'paysage', size: const Size(844, 390), scale: 1.0),
  ]) {
    testWidgets('Page et panneau accessibles : ${scenario.name}', (
      tester,
    ) async {
      await mount(tester, size: scenario.size, scale: scenario.scale);
      expect(tester.takeException(), isNull);
      await tapVisible(tester, find.text('Affiner la recherche'));
      expect(tester.takeException(), isNull);
      await tapVisible(tester, find.text('Plus de 50 chapitres'));
      await tapVisible(tester, find.text('Appliquer les filtres'));
      expect(find.text('Trouver ma lecture').hitTestable(), findsOneWidget);
      await tapVisible(tester, find.text('Trouver ma lecture'));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('La recherche reste accessible avec le clavier ouvert', (
    tester,
  ) async {
    await mount(tester);
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'Une aventure');
    await tester.pumpAndSettle();
    expect(find.text('Trouver ma lecture').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
