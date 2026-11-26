import 'package:entre_les_lignes/engine.dart';
import 'package:entre_les_lignes/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Moteur local, historique et catalogue direct sans PC',
    (tester) async {
      final engine = IrisEngine();
      final history = await engine.request('history') as List;
      expect(history, isNotEmpty);
      expect(history.first['prompt'], isA<String>());
      expect(await engine.configured(), isA<bool>());
      final search = await engine.request(
        'reading/search?title=Genkai%20OL-san%20wa%20Akuyaku%20Reijou-sama%20ni%20Tsukaetai',
      );
      expect(search['works'], isNotEmpty);
      expect(search['works'].first['title'], contains('Genkai'));

      await tester.pumpWidget(const ReadingApp());
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Réglages'));
      await tester.pumpAndSettle();
      expect(find.text('Iris sur ton téléphone'), findsOneWidget);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.obscureText, isTrue);
      expect(field.enableSuggestions, isFalse);
      expect(field.controller!.text, isEmpty);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Historique').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('Impossible de charger'), findsNothing);
      await tester.tap(find.text('Bibliothèque').last);
      await tester.pumpAndSettle();
      expect(find.text('152 titre(s)'), findsOneWidget);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
