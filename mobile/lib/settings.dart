import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'engine.dart';
import 'mangatime.dart';
import 'updates.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage(this.engine, {super.key});
  final IrisEngine engine;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final keyField = TextEditingController();
  bool? configured;
  bool busy = false;
  String? error;
  bool mangaConnected = false, mangaBusy = false;
  String? mangaError;

  @override
  void initState() {
    super.initState();
    load();
    loadMangaTime();
  }

  Future<void> loadMangaTime() async {
    try {
      final value = await MangaTimeSession.configured();
      if (mounted) setState(() => mangaConnected = value);
    } catch (_) {
      // Le réglage est disponible sur Android.
    }
  }

  Future<void> mangaSession({bool remove = false}) async {
    setState(() {
      mangaBusy = true;
      mangaError = null;
    });
    try {
      if (remove) {
        await MangaTimeSession.clear();
      } else {
        await MangaTimeSession.importSession();
      }
      await loadMangaTime();
    } on PlatformException catch (e) {
      if (mounted) {
        setState(() => mangaError = e.message ?? 'Import impossible.');
      }
    } finally {
      if (mounted) setState(() => mangaBusy = false);
    }
  }

  Future<void> load() async {
    try {
      final value = await widget.engine.configured();
      if (mounted) setState(() => configured = value);
    } catch (_) {
      if (mounted) setState(() => error = 'Impossible de lire les réglages.');
    }
  }

  @override
  void dispose() {
    keyField.dispose();
    super.dispose();
  }

  Future<void> save({bool remove = false}) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (remove) {
        await widget.engine.clearKey();
      } else {
        await widget.engine.setKey(keyField.text.trim());
      }
      keyField.clear();
      if (mounted) {
        setState(() => configured = !remove);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              remove
                  ? 'Clé supprimée du téléphone.'
                  : 'Clé enregistrée sur ce téléphone.',
            ),
          ),
        );
      }
    } on PlatformException catch (failure) {
      if (mounted) {
        setState(() => error = failure.message ?? 'Enregistrement impossible.');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Réglages')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          'Iris sur ton téléphone',
          style: TextStyle(fontFamily: 'serif', fontSize: 27),
        ),
        const SizedBox(height: 10),
        const Text(
          'Les conseils et la recherche Web utilisent directement OpenAI par Internet. Aucun PC à laisser allumé.',
        ),
        const SizedBox(height: 20),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            configured == true
                ? Icons.check_circle_outline
                : Icons.key_outlined,
          ),
          title: Text(
            configured == true ? 'Clé API enregistrée' : 'Clé API OpenAI',
          ),
          subtitle: const Text(
            'Chiffrée avec le coffre Android de ce téléphone.',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: keyField,
          enabled: !busy,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.visiblePassword,
          autofillHints: const [],
          decoration: InputDecoration(
            labelText: configured == true ? 'Nouvelle clé API' : 'Ta clé API',
            hintText: 'sk-…',
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'Les appels sont facturés sur ton compte API. Pour personnaliser les conseils, Iris envoie ta demande et des éléments de ta bibliothèque à OpenAI.',
          style: TextStyle(fontSize: 13, color: Color(0xff73675e)),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: busy ? null : () => save(),
          child: Text(busy ? 'Enregistrement…' : 'Enregistrer la clé'),
        ),
        if (configured == true)
          TextButton(
            onPressed: busy ? null : () => save(remove: true),
            child: const Text('Supprimer la clé'),
          ),
        const Divider(height: 36),
        const Text(
          'MangaTime',
          style: TextStyle(fontFamily: 'serif', fontSize: 24),
        ),
        const SizedBox(height: 8),
        Text(
          mangaConnected
              ? 'Session MangaTime enregistrée'
              : 'Connecte MangaTime pour ajouter tes conseils à tes à lire.',
        ),
        const SizedBox(height: 8),
        const Text(
          'Importe le fichier session-mangatime.json déjà utilisé par MangaTime Export. La session est chiffrée sur ce téléphone.',
          style: TextStyle(fontSize: 13),
        ),
        OutlinedButton.icon(
          onPressed: mangaBusy ? null : () => mangaSession(),
          icon: const Icon(Icons.file_open_outlined),
          label: Text(
            mangaBusy
                ? 'Import en cours…'
                : mangaConnected
                ? 'Remplacer la session MangaTime'
                : 'Importer la session MangaTime',
          ),
        ),
        if (mangaConnected)
          TextButton(
            onPressed: mangaBusy ? null : () => mangaSession(remove: true),
            child: const Text('Déconnecter MangaTime'),
          ),
        if (mangaError != null)
          Text(
            mangaError!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        const Divider(height: 36),
        const UpdateSettings(),
        const Divider(height: 36),
        const Text(
          'L’historique et la bibliothèque restent consultables sans connexion. La recherche MangaDex fonctionne sans clé API, avec Internet.',
        ),
      ],
    ),
  );
}
