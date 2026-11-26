import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class RecommendationTitle extends StatelessWidget {
  final String title;
  final TextStyle style;

  const RecommendationTitle(
    this.title, {
    super.key,
    this.style = const TextStyle(
      fontFamily: 'serif',
      fontSize: 28,
      height: 1.15,
    ),
  });

  Future<void> copy(BuildContext context) async {
    String message;
    try {
      await Clipboard.setData(ClipboardData(text: title));
      message = 'Titre copié';
    } catch (_) {
      message = 'Impossible de copier le titre.';
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
      );
  }

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    hint: 'Copier le titre',
    child: Tooltip(
      message: 'Copier le titre',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => copy(context),
          borderRadius: BorderRadius.circular(4),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(title, style: style),
            ),
          ),
        ),
      ),
    ),
  );
}
