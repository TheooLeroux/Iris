import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';

/// Le moteur s'exécute dans l'app Android, sans transport HTTP local.
class IrisEngine {
  static const channel = MethodChannel('iris/engine');
  bool closed = false;
  void close() => closed = true;

  Future<bool> configured() async {
    final status = await channel.invokeMapMethod<String, dynamic>('settings');
    return status?['configured'] == true;
  }

  Future<void> setKey(String key) => channel.invokeMethod<void>('setKey', key);
  Future<void> clearKey() => channel.invokeMethod<void>('clearKey');

  Future<dynamic> request(
    String path, {
    Map? body,
    String? token,
    Duration responseTimeout = const Duration(seconds: 30),
  }) async {
    try {
      final raw = await channel
          .invokeMethod<String>('request', {
            'path': path,
            'body': body == null ? null : jsonEncode(body),
          })
          .timeout(responseTimeout);
      final result = jsonDecode(raw!) as Map;
      if (result['error'] != null) throw FormatException(result['error']);
      return result['data'];
    } on PlatformException catch (error) {
      throw FormatException(error.message ?? 'Action indisponible. Réessaie.');
    } on TimeoutException {
      throw const FormatException(
        'La recherche prend trop de temps. Réessaie dans un instant.',
      );
    }
  }

  Future<Map> advise(Map body) async {
    var job = await request('advise', body: body);
    while (job['status'] == 'running' && !closed) {
      await Future<void>.delayed(const Duration(seconds: 2));
      job = await request('jobs/${job['id']}');
    }
    if (job['status'] != 'done') {
      throw FormatException(job['error'] ?? 'Recherche interrompue.');
    }
    return job['result'] as Map;
  }

  Future<String?> cover(List sources) async {
    for (final source in sources) {
      try {
        final result = await request(
          'cover/${Uri.encodeComponent(source['id'])}',
        );
        if (result['url'] is String) return result['url'];
      } catch (_) {
        continue;
      }
    }
    return null;
  }
}
