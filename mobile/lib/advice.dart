import 'package:flutter/material.dart';

const _ink = Color(0xff302923);
const _muted = Color(0xff73675e);
const _line = Color(0xffe5ded3);
const _accent = Color(0xff8d392c);
const _tint = Color(0xfff4e9e0);

const _publicationOptions = {
  '': 'Peu importe',
  'finished': 'Terminée',
  'ongoing': 'En cours',
};
const _lengthOptions = {
  '': 'Peu importe',
  'short': '1 à 50 chapitres',
  'long': 'Plus de 50 chapitres',
  'very_long': 'Plus de 100 chapitres',
};
const _originOptions = {
  '': 'Toutes',
  'country:JP': 'Manga · Japon',
  'country:KR': 'Manhwa · Corée',
  'country:CN': 'Manhua · Chine',
};
const _genreOptions = {
  'genre:action': 'Action',
  'genre:adventure': 'Aventure',
  'genre:fantasy': 'Fantasy',
  'genre:romance': 'Romance',
  'genre:comedy': 'Comédie',
  'genre:drama': 'Drame',
  'genre:scifi': 'Science-fiction',
  'genre:slice_of_life': 'Tranche de vie',
  'genre:mystery': 'Mystère',
  'genre:horror': 'Horreur',
};
final _filterLabels = {
  ..._publicationOptions,
  ..._lengthOptions,
  ..._originOptions,
  ..._genreOptions,
  'finished': 'Publication terminée',
  'ongoing': 'Publication en cours',
};

String adviceFilterLabel(String value) => _filterLabels[value] ?? value;

class AdviceFilters {
  final Set<String> values;
  final bool absolute;
  const AdviceFilters({this.values = const {}, this.absolute = false});
  int get activeCount => values.length + (absolute ? 1 : 0);
  List<String> get serverValues => _filterLabels.keys
      .where((key) => key.isNotEmpty && values.contains(key))
      .toList();
}

/// The composer owns its draft, so changing tabs keeps the current request.
class AdvicePage extends StatefulWidget {
  final bool loading;
  final Future<void> Function(Map<String, dynamic>) onSearch;

  const AdvicePage({super.key, required this.loading, required this.onSearch});

  @override
  State<AdvicePage> createState() => _AdvicePageState();
}

class _AdvicePageState extends State<AdvicePage> {
  final draft = TextEditingController();
  AdviceFilters filters = const AdviceFilters();
  int count = 5;

  @override
  void dispose() {
    draft.dispose();
    super.dispose();
  }

  Future<void> editFilters() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final result = await showModalBottomSheet<AdviceFilters>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: const Color(0xfffaf8f2),
      builder: (_) => _FilterSheet(initial: filters),
    );
    if (mounted && result != null) setState(() => filters = result);
  }

  Future<void> search() async {
    FocusManager.instance.primaryFocus?.unfocus();
    await widget.onSearch({
      'prompt': draft.text.trim().isEmpty
          ? 'Conseille-moi une lecture'
          : draft.text.trim(),
      'scope': 'discovery',
      'count': count,
      'mode': filters.absolute ? 'absolute' : 'guided',
      'filters': filters.serverValues,
    });
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Flexible(
        fit: FlexFit.loose,
        child: Align(
          alignment: Alignment.topCenter,
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: ListView(
              shrinkWrap: true,
              key: const PageStorageKey('advice-scroll'),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              children: [
                const Text(
                  'Ta prochaine lecture',
                  style: TextStyle(
                    fontFamily: 'serif',
                    fontSize: 28,
                    height: 1.15,
                    color: _ink,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'De nouvelles histoires, hors de ta bibliothèque.',
                  style: TextStyle(color: _muted, fontSize: 12, height: 1.4),
                ),
                const SizedBox(height: 20),
                IgnorePointer(
                  ignoring: widget.loading,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const _Label('Qu’as-tu envie de lire ?'),
                      const SizedBox(height: 10),
                      TextField(
                        controller: draft,
                        enabled: !widget.loading,
                        minLines: 2,
                        maxLines: 5,
                        style: const TextStyle(
                          fontSize: 15,
                          height: 1.5,
                          color: _ink,
                        ),
                        decoration: InputDecoration(
                          hintText: 'Un genre, une ambiance, un personnage…',
                          hintStyle: const TextStyle(
                            color: _muted,
                            fontSize: 14,
                          ),
                          filled: true,
                          fillColor: Colors.white.withValues(alpha: .65),
                          contentPadding: const EdgeInsets.all(14),
                          border: _inputBorder(_line),
                          enabledBorder: _inputBorder(_line),
                          focusedBorder: _inputBorder(_accent, width: 1.5),
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Pas d’idée précise ? Laisse Iris te surprendre.',
                        style: TextStyle(
                          fontSize: 12,
                          color: _muted,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 18),
                      Material(
                        color: Colors.transparent,
                        shape: RoundedRectangleBorder(
                          side: const BorderSide(color: _line),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: ListTile(
                          onTap: widget.loading ? null : editFilters,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 2,
                          ),
                          leading: const Icon(
                            Icons.tune_rounded,
                            size: 21,
                            color: _accent,
                          ),
                          title: const Text(
                            'Affiner la recherche',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: _ink,
                            ),
                          ),
                          subtitle: Text(
                            filters.activeCount == 0
                                ? 'Genres, origine, publication, longueur'
                                : '${filters.activeCount} réglage${filters.activeCount > 1 ? 's' : ''} actif${filters.activeCount > 1 ? 's' : ''}',
                            style: const TextStyle(fontSize: 12, color: _muted),
                          ),
                          trailing: const Icon(
                            Icons.chevron_right_rounded,
                            color: _muted,
                            size: 20,
                          ),
                        ),
                      ),
                      if (filters.activeCount > 0) ...[
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            for (final value in filters.serverValues)
                              _FilterTag(
                                _filterLabels[value]!,
                                () => setState(
                                  () => filters = AdviceFilters(
                                    values: {...filters.values}..remove(value),
                                    absolute: filters.absolute,
                                  ),
                                ),
                              ),
                            if (filters.absolute)
                              _FilterTag(
                                'Demande à la lettre',
                                () => setState(
                                  () => filters = AdviceFilters(
                                    values: filters.values,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 18),
                      Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 12,
                        runSpacing: 10,
                        children: [
                          const Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _Label('Propositions'),
                              SizedBox(height: 3),
                              Text(
                                'De 1 à 5 lectures',
                                style: TextStyle(color: _muted, fontSize: 12),
                              ),
                            ],
                          ),
                          DecoratedBox(
                            decoration: BoxDecoration(
                              border: Border.all(color: _line),
                              borderRadius: BorderRadius.circular(30),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: 'Moins de propositions',
                                  onPressed: count > 1 && !widget.loading
                                      ? () => setState(() => count--)
                                      : null,
                                  icon: const Icon(
                                    Icons.remove_rounded,
                                    size: 18,
                                  ),
                                ),
                                Semantics(
                                  liveRegion: true,
                                  label:
                                      '$count proposition${count > 1 ? 's' : ''}',
                                  excludeSemantics: true,
                                  child: SizedBox(
                                    width: 26,
                                    child: Text(
                                      '$count',
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w700,
                                        color: _ink,
                                      ),
                                    ),
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Plus de propositions',
                                  onPressed: count < 5 && !widget.loading
                                      ? () => setState(() => count++)
                                      : null,
                                  icon: const Icon(Icons.add_rounded, size: 18),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      Container(
        width: double.infinity,
        decoration: const BoxDecoration(
          color: Color(0xfffaf8f2),
          border: Border(top: BorderSide(color: _line)),
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilledButton.icon(
                    onPressed: widget.loading ? null : search,
                    style: FilledButton.styleFrom(
                      backgroundColor: _accent,
                      foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(54),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 16,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    icon: widget.loading
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.auto_stories_outlined, size: 20),
                    label: Text(
                      widget.loading
                          ? 'Recherche en cours…'
                          : 'Trouver ma lecture',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (widget.loading)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Semantics(
                        liveRegion: true,
                        child: const Text(
                          'Iris compare les titres à tes envies. Cela peut prendre un moment.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 12,
                            color: _muted,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    ],
  );
}

OutlineInputBorder _inputBorder(Color color, {double width = 1}) =>
    OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: color, width: width),
    );

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);
  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      color: _ink,
    ),
  );
}

class _FilterTag extends StatelessWidget {
  final String label;
  final VoidCallback onDeleted;
  const _FilterTag(this.label, this.onDeleted);
  @override
  Widget build(BuildContext context) => InputChip(
    label: Text(label, style: const TextStyle(fontSize: 12, color: _accent)),
    onDeleted: onDeleted,
    deleteButtonTooltipMessage: 'Retirer : $label',
    deleteIcon: const Icon(Icons.close_rounded, size: 15, color: _accent),
    backgroundColor: _tint,
    side: BorderSide.none,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
  );
}

class _FilterSheet extends StatefulWidget {
  final AdviceFilters initial;
  const _FilterSheet({required this.initial});
  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late final Set<String> values = {...widget.initial.values};
  late bool absolute = widget.initial.absolute;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .85,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 12, 8),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Tes filtres',
                    style: TextStyle(
                      fontFamily: 'serif',
                      fontSize: 28,
                      color: _ink,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Fermer sans appliquer',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _Label('Origine'),
                  const SizedBox(height: 6),
                  _singleChoices(_originOptions),
                  const SizedBox(height: 16),
                  const _Label('Genres'),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 2,
                    children: [
                      for (final entry in _genreOptions.entries)
                        FilterChip(
                          label: Text(entry.value),
                          selected: values.contains(entry.key),
                          onSelected: (selected) => setState(() {
                            selected
                                ? values.add(entry.key)
                                : values.remove(entry.key);
                          }),
                          selectedColor: _tint,
                          checkmarkColor: _accent,
                          labelStyle: TextStyle(
                            fontSize: 13,
                            color: values.contains(entry.key)
                                ? _accent
                                : _muted,
                          ),
                          side: BorderSide(
                            color: values.contains(entry.key) ? _accent : _line,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Les genres sélectionnés se cumulent.',
                    style: TextStyle(fontSize: 12, color: _muted),
                  ),
                  const SizedBox(height: 16),
                  const _Label('Publication'),
                  const SizedBox(height: 6),
                  _singleChoices(_publicationOptions),
                  const SizedBox(height: 4),
                  const Text(
                    'Statut de la publication d’origine.',
                    style: TextStyle(fontSize: 12, color: _muted),
                  ),
                  const SizedBox(height: 16),
                  const _Label('Longueur'),
                  const SizedBox(height: 6),
                  _singleChoices(_lengthOptions),
                  const SizedBox(height: 18),
                  const Divider(color: _line, height: 1),
                  const SizedBox(height: 16),
                  const _Label('Respect de tes envies'),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    activeTrackColor: _accent,
                    title: const Text(
                      'Suivre ma demande à la lettre',
                      style: TextStyle(fontSize: 14, color: _ink),
                    ),
                    subtitle: Text(
                      absolute
                          ? 'Chaque critère doit être confirmé. Aucune piste exploratoire.'
                          : 'Iris peut proposer une piste voisine, clairement signalée.',
                      style: const TextStyle(
                        fontSize: 12,
                        color: _muted,
                        height: 1.5,
                      ),
                    ),
                    value: absolute,
                    onChanged: (v) => setState(() => absolute = v),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Tous les filtres sélectionnés restent obligatoires dans les deux cas.',
                    style: TextStyle(fontSize: 12, color: _muted, height: 1.4),
                  ),
                ],
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: _line)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: _accent,
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(52),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  onPressed: () => Navigator.pop(
                    context,
                    AdviceFilters(
                      values: Set.unmodifiable(values),
                      absolute: absolute,
                    ),
                  ),
                  child: const Text('Appliquer les filtres'),
                ),
                TextButton(
                  onPressed: values.isNotEmpty || absolute
                      ? () => setState(() {
                          values.clear();
                          absolute = false;
                        })
                      : null,
                  child: const Text('Réinitialiser'),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  Widget _singleChoices(Map<String, String> options) => Wrap(
    spacing: 6,
    runSpacing: 2,
    children: [
      for (final entry in options.entries)
        ChoiceChip(
          label: Text(entry.value),
          selected: entry.key.isEmpty
              ? !options.keys.any(values.contains)
              : values.contains(entry.key),
          onSelected: (_) => setState(() {
            values.removeAll(options.keys);
            if (entry.key.isNotEmpty) values.add(entry.key);
          }),
          selectedColor: _tint,
          backgroundColor: Colors.transparent,
          labelStyle: const TextStyle(color: _ink, fontSize: 13),
          checkmarkColor: _accent,
          side: const BorderSide(color: _line),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
    ],
  );
}
