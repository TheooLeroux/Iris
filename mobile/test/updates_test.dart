import 'dart:async';
import 'package:entre_les_lignes/updates.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  final update = <String, dynamic>{
    'version': '1.4.0',
    'build': 6,
    'size': 100000000,
    'notes': 'Une amélioration utile.',
    'sha256': 'a' * 64,
    'apk_url':
        'https://github.com/TheooLeroux/Iris/releases/download/v1.4.0+6/Iris-1.4.0.apk',
  };
  bool available = true, failure = false, permission = true;
  Completer<void>? download;
  setUp(() {
    calls.clear();
    available = true;
    failure = false;
    permission = true;
    download = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(IrisUpdates.channel, (call) async {
          calls.add(call);
          switch (call.method) {
            case 'installed':
              return {'version': '1.3.0', 'build': 5};
            case 'check':
              if (failure) throw PlatformException(code: 'network');
              return available ? update : null;
            case 'progress':
              return {'received': 50000000, 'total': 100000000};
            case 'download':
              if (download != null) await download!.future;
              if (failure) throw PlatformException(code: 'download');
              return null;
            case 'install':
              return permission;
            case 'cancel':
              download?.completeError(PlatformException(code: 'cancelled'));
              return null;
            default:
              return null;
          }
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(IrisUpdates.channel, null);
  });

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: UpdateSettings())),
    );
    await tester.pumpAndSettle();
  }

  Future<void> check(WidgetTester tester) async {
    await tester.tap(find.text('Rechercher une mise à jour'));
    await tester.pumpAndSettle();
  }

  testWidgets('Version installée et report sans téléchargement', (
    tester,
  ) async {
    await mount(tester);
    expect(find.textContaining('Iris 1.3.0'), findsOneWidget);
    await check(tester);
    expect(find.text('Une nouvelle version d’Iris'), findsOneWidget);
    expect(find.text('Une amélioration utile.'), findsOneWidget);
    await tester.tap(find.text('Plus tard'));
    await tester.pumpAndSettle();
    expect(calls.last.method, 'later');
    expect(calls.last.arguments, 6);
    expect(calls.where((c) => c.method == 'download'), isEmpty);
  });

  testWidgets('Téléchargement demandé puis installation', (tester) async {
    await mount(tester);
    await check(tester);
    await tester.tap(find.text('Mettre à jour'));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.method == 'download').length, 1);
    expect(calls.last.method, 'install');
    expect(find.text('Une nouvelle version d’Iris'), findsNothing);
  });

  testWidgets('Permission Android puis nouvel essai sans retélécharger', (
    tester,
  ) async {
    permission = false;
    await mount(tester);
    await check(tester);
    await tester.tap(find.text('Mettre à jour'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Autorise Iris'), findsOneWidget);
    permission = true;
    await tester.tap(find.text('Installer'));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.method == 'download').length, 1);
    expect(calls.where((c) => c.method == 'install').length, 2);
  });

  testWidgets(
    'Fichier refusé : aucune installation et nouvelle tentative possible',
    (tester) async {
      await mount(tester);
      await check(tester);
      failure = true;
      await tester.tap(find.text('Mettre à jour'));
      await tester.pumpAndSettle();
      expect(find.textContaining('impossible. Réessaie.'), findsOneWidget);
      expect(calls.where((c) => c.method == 'install'), isEmpty);
      await tester.tap(find.text('Plus tard'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('Progression, double clic bloqué et annulation', (tester) async {
    download = Completer<void>();
    await mount(tester);
    await check(tester);
    await tester.tap(find.text('Mettre à jour'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(find.text('Téléchargement · 50 %'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    await tester.tap(find.text('Annuler'));
    await tester.pumpAndSettle();
    expect(find.text('Téléchargement annulé.'), findsOneWidget);
    expect(calls.where((c) => c.method == 'install'), isEmpty);
    await tester.tap(find.text('Plus tard'));
    await tester.pumpAndSettle();
  });

  testWidgets('Aucune nouvelle version et erreur réseau manuelle', (
    tester,
  ) async {
    available = false;
    await mount(tester);
    await check(tester);
    expect(find.text('Iris est à jour.'), findsOneWidget);
    failure = true;
    await check(tester);
    expect(find.textContaining('Vérification impossible'), findsOneWidget);
  });

  testWidgets('Erreur automatique silencieuse et sans installation', (
    tester,
  ) async {
    failure = true;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => IrisUpdates.check(context, automatic: true),
              child: const Text('Automatique'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Automatique'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    expect(calls.single.arguments, false);
  });
}
