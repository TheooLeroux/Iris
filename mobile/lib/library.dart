import 'sync.dart';
import 'package:flutter/material.dart';

class LibraryPage extends StatefulWidget {
  final MangaSync sync;
  const LibraryPage(this.sync, {super.key});
  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  final entries = Future<List<List<String>>>.value([]);
  String query = '';
  bool planned = false;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Bibliothèque',
          style: TextStyle(fontSize: 28, fontFamily: 'serif'),
        ),
        TextButton(
          onPressed: () => widget.sync.refresh(choose: true),
          child: Text(
            widget.sync.file ?? 'Choisir le dossier des exports MangaTime',
          ),
        ),
        if (widget.sync.checked > 0)
          Text(
            'Dernière vérification · ${DateTime.fromMillisecondsSinceEpoch(widget.sync.checked).toLocal().toString().substring(0, 16)}',
          ),
        if (widget.sync.error != null) Text(widget.sync.error!),

        TextField(
          onChanged: (v) => setState(() => query = v.trim().toLowerCase()),
          decoration: const InputDecoration(
            labelText: 'Rechercher un titre',
            prefixIcon: Icon(Icons.search),
            border: OutlineInputBorder(),
          ),
        ),
        FilterChip(
          label: const Text('À lire'),
          selected: planned,
          onSelected: (v) => setState(() => planned = v),
        ),
        Expanded(
          child: FutureBuilder<List<List<String>>>(
            future: entries,
            builder: (context, s) {
              if (s.hasError) {
                return const Text('Impossible de charger la bibliothèque.');
              }
              if (!s.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final rows =
                  (widget.sync.rows?.map(
                            (r) => <String>[r['titre'], r['statut']],
                          ) ??
                          s.requireData)
                      .where(
                        (r) =>
                            (!planned || r[1] == 'À lire') &&
                            r[0].toLowerCase().contains(query),
                      )
                      .toList();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${rows.length} titre(s)'),
                  Expanded(
                    child: ListView.builder(
                      itemCount: rows.length,
                      itemBuilder: (context, i) => ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(rows[i][0]),
                        subtitle: Text(rows[i][1]),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    ),
  );
}
