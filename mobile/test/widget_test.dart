import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:entre_les_lignes/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    final library = List.generate(
      152,
      (i) => {
        'titre': 'Lecture ${i + 1}',
        'statut': i < 25 ? 'À lire' : 'Terminé',
      },
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('iris/library'),
      (_) async => {
        'data': jsonEncode(library),
        'file': 'mangatime-test.json',
        'checked': 1,
      },
    );
    messenger.setMockMethodCallHandler(const MethodChannel('iris/engine'), (
      call,
    ) async {
      if (call.method == 'request') {
        final path = (call.arguments as Map)['path'];
        return jsonEncode({'data': path == 'history' ? [] : library});
      }
      return {'configured': false};
    });
  });
  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('iris/library'),
      null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('iris/engine'),
      null,
    );
  });
  testWidgets('Conseil compact, historique et bibliothèque MangaTime', (
    tester,
  ) async {
    await tester.pumpWidget(const ReadingApp());
    await tester.pumpAndSettle();
    expect(find.text('Ma pile À lire'), findsNothing);
    expect(find.text('À quoi ressemble un conseil ?'), findsNothing);
    await tester.tap(find.text('Historique').last);
    await tester.pumpAndSettle();
    expect(find.text('Exemples enregistrés'), findsNothing);
    expect(find.text('Une demande ou un titre…'), findsOneWidget);
    await tester.tap(find.byType(NavigationDestination).last);
    await tester.pumpAndSettle();
    expect(find.text('152 titre(s)'), findsOneWidget);
    await tester.tap(find.byType(FilterChip));
    await tester.pumpAndSettle();
    expect(find.text('25 titre(s)'), findsOneWidget);
  });
}
