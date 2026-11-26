import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'engine.dart';

class MangaSync extends ChangeNotifier with WidgetsBindingObserver {
  List<dynamic>? rows;
  String? file, error;
  int checked = 0;
  Timer? timer;
  bool active = true, closed = false;
  Future<void>? pending;
  void start() {
    WidgetsBinding.instance.addObserver(this);
    refresh();
    timer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (active &&
          file != null &&
          DateTime.now().millisecondsSinceEpoch - checked >= 3600000) {
        refresh();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    active = state == AppLifecycleState.resumed;
    if (active) refresh();
  }

  Future<void> refresh({bool choose = false}) async {
    if (pending != null) {
      await pending;
      if (!choose) return;
    }
    final task = _read(choose);
    pending = task;
    try {
      await task;
    } finally {
      pending = null;
    }
  }

  Future<void> _read(bool choose) async {
    try {
      final data = await const MethodChannel(
        'iris/library',
      ).invokeMapMethod<String, dynamic>(choose ? 'choose' : 'sync');
      if (data == null) return;
      final exported = data['data'] == null
          ? null
          : jsonDecode(data['data'] as String) as List;
      rows =
          await IrisEngine().request(
                'mangatime/library',
                body: {'library': exported},
              )
              as List;
      checked = data['checked'] as int;
      file = data['file'] as String?;
      error = data['error'] as String?;
    } on MissingPluginException {
      return;
    } catch (e) {
      error = 'Accès au dossier impossible.';
    }
    if (!closed) notifyListeners();
  }

  @override
  void dispose() {
    closed = true;
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
