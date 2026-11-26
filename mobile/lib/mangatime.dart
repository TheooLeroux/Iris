import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'engine.dart';

class MangaTimeSession {
  static const channel = MethodChannel('iris/mangatime');
  static Future<bool> configured() async =>
      await channel.invokeMethod<bool>('configured') ?? false;
  static Future<bool> importSession() async =>
      await channel.invokeMethod<bool>('import') ?? false;
  static Future<void> clear() => channel.invokeMethod<void>('clear');
}

class MangaTimeButton extends StatefulWidget {
  final IrisEngine engine;
  final Map work;
  final Future<void> Function() onChanged;
  const MangaTimeButton({
    super.key,
    required this.engine,
    required this.work,
    required this.onChanged,
  });

  @override
  State<MangaTimeButton> createState() => _MangaTimeButtonState();
}

class _MangaTimeButtonState extends State<MangaTimeButton> {
  Map state = {};
  bool busy = true, uncertain = false;
  String? error;

  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<dynamic> request(String action, [Map extra = const {}]) =>
      widget.engine.request(
        'mangatime/$action',
        body: {'work': widget.work, ...extra},
        responseTimeout: const Duration(minutes: 3),
      );

  Future<void> refresh() async {
    try {
      final result = await request('state') as Map;
      if (mounted) {
        setState(() {
          state = result;
          uncertain = false;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          uncertain = true;
          error = _message(e);
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  String _message(Object e) => e is FormatException
      ? e.message
      : e is PlatformException
      ? e.message ?? 'Connexion MangaTime impossible.'
      : 'Connexion MangaTime impossible. Réessaie.';

  Future<void> act() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (!await MangaTimeSession.configured()) {
        if (!mounted) return;
        final proceed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Connecter MangaTime'),
            content: const Text(
              'Choisis le fichier session-mangatime.json déjà utilisé pour MangaTime Export. La session sera chiffrée sur ce téléphone.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Plus tard'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Choisir la session'),
              ),
            ],
          ),
        );
        if (proceed != true || !await MangaTimeSession.importSession()) return;
      }
      if (uncertain) {
        await refresh();
        if (!uncertain) await widget.onChanged();
        return;
      }
      Map result;
      if (state['can_remove'] == true) {
        result =
            await request('set', {'id': state['id'], 'added': false}) as Map;
      } else {
        final candidates = await request('search') as List;
        if (!mounted) return;
        if (candidates.isEmpty) {
          setState(
            () => error = 'Aucune fiche trouvée dans MangaTime pour ce titre.',
          );
          return;
        }
        final choice = await showModalBottomSheet<Map>(
          context: context,
          showDragHandle: true,
          isScrollControlled: true,
          builder: (context) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Choisir la fiche MangaTime',
                    style: TextStyle(fontFamily: 'serif', fontSize: 24),
                  ),
                  const SizedBox(height: 8),
                  Text('Pour « ${widget.work['title']} »'),
                  const SizedBox(height: 8),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.sizeOf(context).height * .55,
                    ),
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final candidate in candidates)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text('${candidate['title']}'),
                            subtitle: Text(
                              candidate['status'] == null
                                  ? 'Ajouter à mes à lire'
                                  : 'Déjà dans ta bibliothèque · ${candidate['status']}',
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () =>
                                Navigator.pop(context, candidate as Map),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        if (choice == null || !mounted) return;
        result =
            await request('set', {'id': choice['id'], 'added': true}) as Map;
      }
      if (!mounted) return;
      setState(() => state = result);
      await widget.onChanged();
    } catch (e) {
      if (mounted) {
        setState(() {
          error = _message(e);
          uncertain = true;
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final present = state['status'] != null;
    final removable = state['can_remove'] == true;
    final label = busy
        ? 'Vérification MangaTime…'
        : uncertain
        ? 'Actualiser l’état MangaTime'
        : removable
        ? 'Retirer de mes à lire MangaTime'
        : present
        ? 'MangaTime · ${state['status']}'
        : 'Ajouter à mes à lire MangaTime';
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          OutlinedButton.icon(
            onPressed: busy || (present && !removable && !uncertain)
                ? null
                : act,
            icon: busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    uncertain
                        ? Icons.refresh
                        : removable
                        ? Icons.bookmark_remove_outlined
                        : Icons.bookmark_add_outlined,
                    size: 20,
                  ),
            label: Text(label),
          ),
          if (error != null)
            Text(
              error!,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontSize: 12,
              ),
            ),
        ],
      ),
    );
  }
}
