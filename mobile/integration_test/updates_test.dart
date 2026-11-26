import 'package:entre_les_lignes/engine.dart';
import 'package:entre_les_lignes/updates.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Pont Android des mises à jour et conservation des données', (
    tester,
  ) async {
    final installed = await IrisUpdates.channel
        .invokeMapMethod<String, dynamic>('installed');
      expect(installed!['build'], 6);
      expect(installed['version'], '1.3.1');
    final progress = await IrisUpdates.channel.invokeMapMethod<String, dynamic>(
      'progress',
    );
    expect(progress!['received'], 0);
    final engine = IrisEngine();
    final history = await engine.request('history') as List;
    expect(history, isNotEmpty);
    final library = await engine.request('mangatime/library') as List;
    expect(library, isNotEmpty);
    // Une app sans téléchargement valide ne doit pas lancer l'installateur.
    await expectLater(
      IrisUpdates.channel.invokeMethod<bool>('install'),
      throwsA(isA<Exception>()),
    );
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: UpdateSettings())),
    );
    await tester.pumpAndSettle();
      expect(find.textContaining('Iris 1.3.1'), findsOneWidget);
    expect(find.text('Rechercher une mise à jour'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
