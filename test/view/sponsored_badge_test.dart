import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sidequests/models/quest.dart';
import 'package:sidequests/view/widgets/sponsored_badge.dart';

/// BQ12: sponsored quests are always labelled, and the model reads the same
/// sponsor columns as Kotlin's QuestDto (Sidequests-Backend migration 010).
Map<String, dynamic> _row({Map<String, dynamic> extra = const {}}) => {
  'id': 'sponsored-climbing',
  'title': 'First Climb at Boulder Box',
  'category': 'Movement',
  'duration_minutes': 45,
  'difficulty': 'medium',
  'location_mode': 'gps',
  'social_level': 'solo',
  'is_sponsored': true,
  'sponsor_name': 'Boulder Box',
  ...extra,
};

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: Center(child: child)));

void main() {
  group('Quest.fromJson', () {
    test('reads the sponsor business category, distinct from the activity category', () {
      final quest = Quest.fromJson(_row(extra: {'sponsor_business_category': 'fitness_and_recreation'}));
      expect(quest.isSponsored, isTrue);
      expect(quest.sponsorName, 'Boulder Box');
      expect(quest.sponsorBusinessCategory, 'fitness_and_recreation');
      expect(quest.category, 'Movement');
    });

    test('a row saved before migration 010 still decodes, without a business category', () {
      final quest = Quest.fromJson(_row());
      expect(quest.isSponsored, isTrue);
      expect(quest.sponsorBusinessCategory, isNull);
    });

    test('an ordinary quest is not sponsored', () {
      final quest = Quest.fromJson(_row(extra: {'is_sponsored': false, 'sponsor_name': null}));
      expect(quest.isSponsored, isFalse);
      expect(quest.sponsorBusinessCategory, isNull);
    });
  });

  group('SponsoredBadge', () {
    testWidgets('says "Patrocinada" on cards', (tester) async {
      await tester.pumpWidget(_host(const SponsoredBadge(sponsorName: 'Boulder Box')));
      expect(find.text('Patrocinada'), findsOneWidget);
    });

    testWidgets('names the sponsor in the detail view', (tester) async {
      await tester.pumpWidget(
        _host(const SponsoredBadge(sponsorName: ' Boulder Box ', showSponsorName: true)),
      );
      expect(find.text('Patrocinada por Boulder Box'), findsOneWidget);
    });

    testWidgets('stays labelled when the sponsor has no name', (tester) async {
      await tester.pumpWidget(_host(const SponsoredBadge(sponsorName: '  ', showSponsorName: true)));
      expect(find.text('Patrocinada'), findsOneWidget);
    });

    testWidgets('a long sponsor name is cut, not overflowed, in a narrow space', (tester) async {
      await tester.pumpWidget(
        _host(
          const SizedBox(
            width: 140,
            child: SponsoredBadge(
              sponsorName: 'Fundación Museo de Arte Moderno de Bogotá y Amigos del Centro',
              showSponsorName: true,
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.textContaining('Patrocinada por'), findsOneWidget);
    });
  });
}
