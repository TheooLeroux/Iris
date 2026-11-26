import 'package:entre_les_lignes/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const live = bool.fromEnvironment('IRIS_LIVE_READING_TEST');

  testWidgets(
    'Recherche du chapitre 41 dans Iris',
    (tester) async {
      await tester.pumpWidget(const ReadingApp());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Où lire', skipOffstage: true).last);
      await tester.pumpAndSettle();

      const title = 'Genkai OL-san wa Akuyaku Reijou-sama ni Tsukaetai';
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), title);
      await tester.enterText(fields.at(1), '41');
      await tester.tap(find.text('Trouver les chapitres'));
      await waitForSearch(tester);
      expect(find.text('Choisis la bonne œuvre.'), findsNothing);

      final warning = find.textContaining('La recherche Web n’a pas abouti');
      expect(warning, findsNothing);
      final details = find.text('Chapitres disponibles');
      expect(details, findsOneWidget);
      final japanese = find.text('Chapitre 41 · Japonais');
      await tester.scrollUntilVisible(
        japanese,
        160,
        scrollable: find.byType(Scrollable).first,
      );
      expect(japanese, findsWidgets);
      expect(find.text('Sites indépendants'), findsNothing);
      expect(find.text('Plateformes officielles référencées'), findsNothing);
    },
    skip: !live,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

Future<void> waitForSearch(WidgetTester tester) async {
  await tester.pump();
  final limit = DateTime.now().add(const Duration(minutes: 3));
  while (find.byType(LinearProgressIndicator).evaluate().isNotEmpty) {
    if (DateTime.now().isAfter(limit)) fail('La recherche ne se termine pas.');
    await Future<void>.delayed(const Duration(milliseconds: 350));
    await tester.pump();
  }
  await tester.pumpAndSettle();
}
