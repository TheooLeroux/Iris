import 'dart:convert';
import 'package:entre_les_lignes/engine.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(IrisEngine.channel, null));

  test(
    'La demande Unicode et la bibliothèque vont au moteur Android',
    () async {
      final body = {
        'prompt': 'Romance GL Vampire · héroïne déterminée 🦇',
        'filters': ['finished', 'genre:romance'],
        'count': 5,
        'library': [
          {'titre': 'Une œuvre à lire', 'statut': 'À lire'},
        ],
      };
      messenger.setMockMethodCallHandler(IrisEngine.channel, (call) async {
        expect(call.method, 'request');
        expect(call.arguments['path'], 'advise');
        expect(jsonDecode(call.arguments['body']), body);
        return jsonEncode({
          'data': {'accepted': true},
        });
      });
      expect(await IrisEngine().request('advise', body: body), {
        'accepted': true,
      });
    },
  );

  test('Les erreurs locales sont affichables sans référence au PC', () async {
    messenger.setMockMethodCallHandler(
      IrisEngine.channel,
      (_) async => jsonEncode({'error': 'Catalogue indisponible.'}),
    );
    await expectLater(
      IrisEngine().request('history'),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'Catalogue indisponible.',
        ),
      ),
    );
  });

  test('Le coffre reçoit la clé, les requêtes n’en contiennent pas', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(IrisEngine.channel, (call) async {
      calls.add(call);
      if (call.method == 'settings') return {'configured': true};
      if (call.method == 'request') return jsonEncode({'data': []});
      return null;
    });
    final engine = IrisEngine();
    await engine.setKey('sk-test-factice');
    expect(await engine.configured(), isTrue);
    await engine.request('history');
    await engine.clearKey();
    expect(calls.map((c) => c.method), [
      'setKey',
      'settings',
      'request',
      'clearKey',
    ]);
    expect(calls[2].arguments, {'path': 'history', 'body': null});
  });

  test('Une erreur Android devient une erreur lisible', () async {
    messenger.setMockMethodCallHandler(
      IrisEngine.channel,
      (_) async => throw PlatformException(
        code: 'engine',
        message: 'Action indisponible.',
      ),
    );
    await expectLater(
      IrisEngine().request('history'),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'Action indisponible.',
        ),
      ),
    );
  });
}
