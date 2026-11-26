import 'dart:async';
import 'package:entre_les_lignes/engine.dart';
import 'package:entre_les_lignes/mangatime.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeEngine extends IrisEngine {
  final calls = <String>[];
  bool added = false, fail = false, existing = false;
  Completer<void>? waiting;
  @override
  Future<dynamic> request(
    String path, {
    Map? body,
    String? token,
    Duration responseTimeout = const Duration(seconds: 30),
  }) async {
    calls.add(path);
    if (path.endsWith('search')) {
      return [
        {'id': 'selected-id', 'title': 'Le titre MangaTime', 'status': null},
      ];
    }
    if (path.endsWith('set')) {
      await waiting?.future;
      if (fail) throw const FormatException('Action non confirmée.');
      added = body!['added'] == true;
    }
    return {
      'id': 'selected-id',
      'added': added,
      'can_remove': added && !existing,
      'status': added ? 'À lire' : null,
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MangaTimeSession.channel, (_) async => true);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MangaTimeSession.channel, null);
  });

  Future<void> mount(
    WidgetTester tester,
    FakeEngine engine, {
    Future<void> Function()? changed,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MangaTimeButton(
            engine: engine,
            work: const {'title': 'Le conseil'},
            onChanged: changed ?? () async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Ajout après choix de fiche, puis annulation', (tester) async {
    final engine = FakeEngine();
    var changes = 0;
    await mount(
      tester,
      engine,
      changed: () async {
        changes++;
      },
    );
    await tester.tap(find.text('Ajouter à mes à lire MangaTime'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(engine.calls.where((c) => c.endsWith('/set')), isEmpty);
    await tester.tap(find.text('Le titre MangaTime'));
    await tester.pumpAndSettle();
    expect(find.text('Retirer de mes à lire MangaTime'), findsOneWidget);
    await tester.tap(find.text('Retirer de mes à lire MangaTime'));
    await tester.pumpAndSettle();
    expect(find.text('Ajouter à mes à lire MangaTime'), findsOneWidget);
    expect(changes, 2);
  });

  testWidgets('Fermer le choix de fiche ne modifie rien', (tester) async {
    final engine = FakeEngine();
    await mount(tester, engine);
    await tester.tap(find.text('Ajouter à mes à lire MangaTime'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    Navigator.of(tester.element(find.text('Choisir la fiche MangaTime'))).pop();
    await tester.pumpAndSettle();
    expect(engine.calls.where((c) => c.endsWith('/set')), isEmpty);
  });

  testWidgets('Un ajout existant est retrouvé à la réouverture', (
    tester,
  ) async {
    final engine = FakeEngine()..added = true;
    await mount(tester, engine);
    expect(find.text('Retirer de mes à lire MangaTime'), findsOneWidget);
  });

  testWidgets('Une lecture préexistante ne peut pas être retirée', (
    tester,
  ) async {
    final engine = FakeEngine()
      ..added = true
      ..existing = true;
    await mount(tester, engine);
    expect(find.text('MangaTime · À lire'), findsOneWidget);
    expect(
      tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
      isNull,
    );
  });

  testWidgets('Une erreur demande une actualisation sans fausse réussite', (
    tester,
  ) async {
    final engine = FakeEngine()
      ..added = true
      ..fail = true;
    await mount(tester, engine);
    await tester.tap(find.text('Retirer de mes à lire MangaTime'));
    await tester.pumpAndSettle();
    expect(find.text('Action non confirmée.'), findsOneWidget);
    expect(find.text('Actualiser l’état MangaTime'), findsOneWidget);
    await tester.tap(find.text('Actualiser l’état MangaTime'));
    await tester.pumpAndSettle();
    expect(find.text('Retirer de mes à lire MangaTime'), findsOneWidget);
    expect(engine.calls.where((c) => c.endsWith('/set')).length, 1);
  });

  testWidgets('Le bouton est désactivé pendant la modification', (
    tester,
  ) async {
    final engine = FakeEngine()
      ..added = true
      ..waiting = Completer<void>();
    await mount(tester, engine);
    await tester.tap(find.text('Retirer de mes à lire MangaTime'));
    await tester.pump();
    expect(
      tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
      isNull,
    );
    engine.waiting!.complete();
    await tester.pumpAndSettle();
    expect(engine.calls.where((c) => c.endsWith('/set')).length, 1);
  });
}
