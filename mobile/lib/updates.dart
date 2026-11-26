import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class IrisUpdates {
  static const channel = MethodChannel('iris/updates');
  static bool _showing = false;

  static Future<void> check(
    BuildContext context, {
    bool automatic = false,
  }) async {
    if (_showing) return;
    _showing = true;
    if (!automatic && context.mounted) {
      ScaffoldMessenger.of(context).clearSnackBars();
    }
    try {
      final update = await channel.invokeMapMethod<String, dynamic>(
        'check',
        !automatic,
      );
      if (!context.mounted) return;
      if (automatic && ModalRoute.of(context)?.isCurrent != true) return;
      if (update == null) {
        if (!automatic) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Iris est à jour.')));
        }
        return;
      }
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _UpdateDialog(update),
      );
    } on MissingPluginException {
      // Les mises à jour installables concernent Android.
    } catch (_) {
      if (context.mounted && !automatic) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Vérification impossible. Vérifie Internet et réessaie.',
            ),
          ),
        );
      }
    } finally {
      _showing = false;
    }
  }
}

class UpdateSettings extends StatefulWidget {
  const UpdateSettings({super.key});
  @override
  State<UpdateSettings> createState() => _UpdateSettingsState();
}

class _UpdateSettingsState extends State<UpdateSettings> {
  bool busy = false;
  String? version;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final info = await IrisUpdates.channel.invokeMapMethod<String, dynamic>(
        'installed',
      );
      if (mounted) setState(() => version = info?['version'] as String?);
    } catch (_) {
      /* Android uniquement. */
    }
  }

  Future<void> check() async {
    setState(() => busy = true);
    await IrisUpdates.check(context);
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'Mises à jour',
        style: TextStyle(fontFamily: 'serif', fontSize: 24),
      ),
      const SizedBox(height: 8),
      Text(
        version == null
            ? 'Iris vérifie les nouvelles versions à l’ouverture.'
            : 'Iris $version · Vérification à l’ouverture',
      ),
      OutlinedButton.icon(
        onPressed: busy ? null : check,
        icon: const Icon(Icons.system_update_outlined),
        label: Text(busy ? 'Vérification…' : 'Rechercher une mise à jour'),
      ),
    ],
  );
}

class _UpdateDialog extends StatefulWidget {
  final Map<String, dynamic> update;
  const _UpdateDialog(this.update);
  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  bool busy = false, ready = false, permission = false, cancelling = false;
  double? progress;
  String? error;
  Timer? timer;

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> poll() async {
    try {
      final info = await IrisUpdates.channel.invokeMapMethod<String, dynamic>(
        'progress',
      );
      if (!mounted || info == null) return;
      final total = info['total'] as num;
      if (total > 0) {
        setState(
          () => progress = ((info['received'] as num) / total).clamp(0.0, 1.0),
        );
      }
    } catch (_) {
      /* Le téléchargement conserve sa propre vérification. */
    }
  }

  Future<void> install() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (!ready) {
        timer = Timer.periodic(
          const Duration(milliseconds: 400),
          (_) => poll(),
        );
        await IrisUpdates.channel.invokeMethod<void>(
          'download',
          jsonEncode(widget.update),
        );
        if (!mounted) return;
        setState(() => ready = true);
      }
      if (!mounted) return;
      final launched = await IrisUpdates.channel.invokeMethod<bool>('install');
      if (!mounted) return;
      if (launched == true) {
        Navigator.pop(context);
      } else {
        setState(() => permission = true);
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => error = cancelling
              ? 'Téléchargement annulé.'
              : 'Téléchargement ou installation impossible. Réessaie.',
        );
      }
    } finally {
      timer?.cancel();
      if (mounted) {
        setState(() {
          busy = false;
          cancelling = false;
        });
      }
    }
  }

  Future<void> later() async {
    await IrisUpdates.channel.invokeMethod<void>(
      'later',
      widget.update['build'],
    );
    if (mounted) Navigator.pop(context);
  }

  Future<void> cancel() async {
    setState(() => cancelling = true);
    await IrisUpdates.channel.invokeMethod<void>('cancel');
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: const Text('Une nouvelle version d’Iris'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Version ${widget.update['version']} · ${((widget.update['size'] as num) / 1048576).toStringAsFixed(0)} Mo',
            ),
            const SizedBox(height: 12),
            if ((widget.update['notes'] as String? ?? '').isNotEmpty)
              Text(widget.update['notes'] as String),
            const SizedBox(height: 12),
            const Text(
              'Tes données sont conservées. Android te demandera de confirmer l’installation.',
            ),
            if (permission)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text(
                  'Autorise Iris à installer ses mises à jour dans les réglages Android, puis appuie sur Installer.',
                ),
              ),
            if (busy) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(value: ready ? null : progress),
              const SizedBox(height: 6),
              Text(
                cancelling
                    ? 'Annulation…'
                    : ready
                    ? 'Ouverture de l’installation…'
                    : 'Téléchargement${progress == null ? '…' : ' · ${(progress! * 100).round()} %'}',
              ),
            ],
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? (cancelling ? null : cancel) : later,
          child: Text(busy ? 'Annuler' : 'Plus tard'),
        ),
        FilledButton(
          onPressed: busy ? null : install,
          child: Text(ready ? 'Installer' : 'Mettre à jour'),
        ),
      ],
    ),
  );
}
