import 'package:entre_les_lignes/reading_titles.dart';
import 'package:flutter_test/flutter_test.dart';

Map saved(String title, {List<String> aliases = const [], int created = 1}) => {
  'status': 'done',
  'created': created,
  'result': {
    'recommendations': [
      {
        'work': {
          'title': title,
          'sources': [
            {
              'fields': {'aliases': aliases.join(' | ')},
            },
          ],
        },
      },
    ],
  },
};

void main() {
  test(
    'Conseils et bibliothèque sont réunis sans doublons, avec les alias',
    () {
      final entries = readingTitles(
        history: [
          saved('吸血鬼小姐的欺负游戏', aliases: ['Miss Vampire’s Bullying Game']),
          saved('Lora', created: 2),
        ],
        library: [
          {'titre': "Miss Vampire's Bullying Game"},
          ['Solo Leveling', 'Terminé'],
        ],
      );
      expect(entries.map((entry) => entry.title), [
        'Lora',
        '吸血鬼小姐的欺负游戏',
        'Solo Leveling',
      ]);
      final vampire = matchingReadingTitles(entries, 'vampire bullying').single;
      expect(vampire.source, 'Proposé · Bibliothèque');
      expect(matchingReadingTitles(entries, '吸血鬼').single, vampire);
      expect(
        matchingReadingTitles(entries, 'solo').single.source,
        'Bibliothèque',
      );
    },
  );

  test('La recherche tolère accents, casse, ponctuation et ordre des mots', () {
    final entries = readingTitles(
      history: [],
      library: [
        ['La Fiancée de la Vilaine'],
        ['Mage & Demon Queen'],
      ],
    );
    expect(
      matchingReadingTitles(entries, 'FIANCEE').single.title,
      'La Fiancée de la Vilaine',
    );
    expect(
      matchingReadingTitles(entries, 'queen mage').single.title,
      'Mage & Demon Queen',
    );
    expect(
      matchingReadingTitles(entries, 'mage and demon').single.title,
      'Mage & Demon Queen',
    );
    expect(matchingReadingTitles(entries, 'inconnu'), isEmpty);
  });

  test('Les conseils récents et la bibliothèque sont suggérés sans texte', () {
    final entries = readingTitles(
      history: [saved('Ancien', created: 1), saved('Récent', created: 2)],
      library: [
        ['Titre de bibliothèque'],
      ],
    );
    expect(matchingReadingTitles(entries, '').map((entry) => entry.title), [
      'Récent',
      'Ancien',
      'Titre de bibliothèque',
    ]);
    expect(matchingReadingTitles(entries, '', limit: 1).single.title, 'Récent');
    expect(matchingReadingTitles(entries, '', limit: 0), isEmpty);
  });

  test(
    'Les anciens conseils fonctionnent, les erreurs et titres vides sont ignorés',
    () {
      final entries = readingTitles(
        history: [
          {
            'status': 'done',
            'result': {
              'work': {'title': 'Ancien format'},
            },
          },
          {
            'status': 'error',
            'result': {
              'work': {'title': 'Pas un conseil'},
            },
          },
        ],
        library: [
          [],
          {},
          {'titre': ''},
        ],
      );
      expect(entries.single.title, 'Ancien format');
    },
  );
}
