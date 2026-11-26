import 'package:entre_les_lignes/engine.dart';
import 'package:entre_les_lignes/history.dart';
import 'package:entre_les_lignes/main.dart';
import 'package:entre_les_lignes/mangatime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Bouton historique et session via le moteur Android', (
    tester,
  ) async {
    final engine = IrisEngine();
    final connected = await MangaTimeSession.configured();
    expect(connected, isA<bool>());
    final state = await engine.request(
      'mangatime/state',
      body: {
        'work': {'title': 'Test Android sans ajout'},
      },
    );
    expect(state['added'], false);
    final library =
        await engine.request('mangatime/library', body: {'library': <Map>[]})
            as List;
    expect(library, isEmpty);
    if (!connected) {
      await expectLater(
        engine.request(
          'mangatime/search',
          body: {
            'work': {'title': 'Bloom Into You'},
          },
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'session',
            contains('Session MangaTime'),
          ),
        ),
      );
    }

    final history = await engine.request('history') as List;
    final recent =
        history.firstWhere(
              (run) => historyRecommendations(run as Map).isNotEmpty,
            )
            as Map;
    final title =
        historyRecommendations(recent).first['work']['title'] as String;
    await tester.pumpWidget(const ReadingApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Historique').last);
    await tester.pumpAndSettle();
    final titleFinder = find.text(title).first;
    await tester.ensureVisible(titleFinder);
    await tester.tap(titleFinder);
    await tester.pumpAndSettle();
    expect(find.text('Ajouter à mes à lire MangaTime'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Réglages'));
    await tester.pumpAndSettle();
    final sessionButton = find.text(
      connected
          ? 'Remplacer la session MangaTime'
          : 'Importer la session MangaTime',
    );
    await tester.ensureVisible(sessionButton);
    await tester.pumpAndSettle();
    expect(sessionButton, findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
