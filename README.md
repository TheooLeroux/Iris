# Iris

Application Android personnelle de conseil de lecture, en Flutter avec un moteur Python embarqué. Les recherches utilisent une clé API configurée sur le téléphone ; l’historique, la bibliothèque et les sessions restent dans ses données privées.

## Publier une mise à jour

1. Modifier le code et les notes dans `mobile/release-notes.txt`.
2. Augmenter la version **et le numéro de build** dans `mobile/pubspec.yaml`, par exemple `1.3.1+6`.
3. Committer et pousser sur `main`.

GitHub Actions exécute les vérifications, compile l’APK avec la signature existante et publie une release contenant l’APK et `iris-update.json`. Une version déjà publiée n’est jamais écrasée. Sans augmentation de version, le push vérifie le code sans créer de nouvelle distribution.

Iris vérifie les versions à l’ouverture et au retour dans l’app, au plus une fois toutes les six heures. Une nouvelle version propose « Plus tard » ou « Mettre à jour ». Le report masque cette version pendant 24 heures. La vérification manuelle reste disponible dans Réglages. Une panne réseau n’empêche jamais l’utilisation de l’app.

Après téléchargement, Iris contrôle la taille, le SHA-256, l’identifiant de l’application, le numéro de build et la signature Android. Android demande la confirmation d’installation et, la première fois, l’autorisation d’installer depuis Iris. Les installations ne sont jamais silencieuses. L’historique, les réglages et les sessions sont conservés.

## Première mise en place

Le dépôt GitHub attendu est `TheooLeroux/Iris`, public pour permettre les téléchargements sans compte GitHub dans l’app. Il contient uniquement le code et les versions distribuables.

Configurer le secret GitHub Actions `IRIS_ANDROID_KEYSTORE_BASE64` avec la clé qui signe déjà l’application installée. Elle doit rester identique pour préserver la compatibilité des mises à jour. La clé elle-même n’est jamais versionnée. Le workflow utilise son `GITHUB_TOKEN` limité au dépôt pour publier les releases.

La version précédente d’Iris ne connaît pas encore ce mécanisme : une première installation manuelle de la version 1.3 est nécessaire. Pour l’installation personnelle existante, une APK locale de transition garde les anciennes données initiales et les copie dans les données privées de l’app. Cette APK n’est pas publiée. Les APK distribuées par GitHub démarrent avec une bibliothèque et un historique vides sur un nouveau téléphone ; une mise à jour conserve les données déjà présentes.

## Compilation locale

Flutter 3.41.4 / Dart 3.11.1, JDK 17, Android SDK 36 et Python 3.11. Depuis `mobile`, exécuter `flutter build apk --release`. L’APK est dans `mobile/build/app/outputs/flutter-apk/app-release.apk`.

Les modules Python viennent de `prototype`. Les données initiales publiques vides viennent de `mobile/seed`. Les exports, caches, bases, captures, anciennes APK et clés sont exclus du dépôt. Le script `scripts/release.py` refuse de préparer un manifeste si l’APK contient une base ou une bibliothèque personnelle.

La variable locale `IRIS_PERSONAL_BOOTSTRAP=1` construit exclusivement une APK privée de transition à partir des fichiers personnels présents sur la machine. Cette option n’est jamais activée dans GitHub Actions et le contrôle de distribution refuse ces APK.

## Vérifications

Dans `mobile` : `flutter analyze` et `flutter test`. Les tests de distribution sont autonomes : `python -m unittest discover -s scripts -p test_*.py`. Les tests Python du moteur liés aux anciennes données personnelles nécessitent ces fichiers locaux ; GitHub exécute les tests autonomes d’intégration de bibliothèque et de MangaTime avec des données synthétiques.
