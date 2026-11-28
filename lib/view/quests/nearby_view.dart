import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/distance.dart';
import '../../models/quest.dart';
import '../../viewmodel/quests/quest_view_model.dart';
import '../widgets/sponsored_badge.dart';
import 'quest_detail_view.dart';

/// "Cerca" tab: GPS-mode quests, sorted by real distance once the user
/// shares their location. Sidequests-Backend's seed catalogue currently has
/// no coordinates on any quest (`latitude`/`longitude` are null for every
/// seeded row), so distance shows honestly as unavailable rather than a
/// fabricated number until the backend populates real coordinates.
class NearbyView extends StatefulWidget {
  const NearbyView({super.key});

  @override
  State<NearbyView> createState() => _NearbyViewState();
}

class _NearbyViewState extends State<NearbyView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => context.read<QuestViewModel>().load());
  }

  @override
  Widget build(BuildContext context) {
    final questViewModel = context.watch<QuestViewModel>();
    final gpsQuests = questViewModel.catalog.where((q) => q.locationMode == 'gps').toList();

    final withDistance = <(Quest, double)>[];
    final withoutDistance = <Quest>[];
    for (final quest in gpsQuests) {
      final distance = _distanceKmFor(questViewModel, quest);
      if (distance != null) {
        withDistance.add((quest, distance));
      } else {
        withoutDistance.add(quest);
      }
    }
    withDistance.sort((a, b) => a.$2.compareTo(b.$2));

    final textTheme = Theme.of(context).textTheme;
    final primary = Theme.of(context).colorScheme.primary;
    void openDetail(Quest quest) =>
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => QuestDetailView(quest: quest)));

    // Kotlin's NearbyScreen: header, radar, location button, "AVAILABLE · n"
    // and plain cards, 12 dp apart.
    final children = <Widget>[
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('LOCATION QUESTS', style: textTheme.labelMedium?.copyWith(color: primary, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text('Where are you headed today?', style: textTheme.headlineSmall),
          const SizedBox(height: 4),
          Text('${gpsQuests.length} places to explore', style: textTheme.bodySmall),
        ],
      ),
      _RadarGraphic(color: primary),
      if (questViewModel.userLatitude == null)
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FilledButton(
              onPressed: questViewModel.isLocatingUser ? null : questViewModel.requestUserLocation,
              child: Text(
                questViewModel.isLocatingUser ? 'Getting your location…' : 'Turn on location to see distances',
              ),
            ),
            if (questViewModel.userLocationUnavailable) ...[
              const SizedBox(height: 8),
              Text(
                'Could not get your location. Check that location is on and Sidequests has permission.',
                style: textTheme.bodySmall,
              ),
            ],
          ],
        ),
      Text('AVAILABLE · ${gpsQuests.length}', style: textTheme.labelMedium),
      if (gpsQuests.isEmpty)
        questViewModel.isLoading
            ? const Align(alignment: Alignment.centerLeft, child: CircularProgressIndicator())
            : Text('No location quests are available right now.', style: textTheme.bodyLarge),
      for (final (quest, distanceKm) in withDistance)
        _NearbyCard(
          quest: quest,
          distanceLabel: '${distanceKm.toStringAsFixed(1)} km',
          onTap: () => openDetail(quest),
        ),
      for (final quest in withoutDistance) _NearbyCard(quest: quest, onTap: () => openDetail(quest)),
    ];

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: questViewModel.load,
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            itemCount: children.length,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (_, index) => children[index],
          ),
        ),
      ),
    );
  }

  double? _distanceKmFor(QuestViewModel questViewModel, Quest quest) {
    final userLat = questViewModel.userLatitude;
    final userLon = questViewModel.userLongitude;
    if (userLat == null || userLon == null) return null;
    if (quest.latitude == null || quest.longitude == null) return null;
    return haversineKm(userLat, userLon, quest.latitude!, quest.longitude!);
  }
}

/// Kotlin's radar: three thin rings (radius 90/65/40 dp, primary at 16 %)
/// around a filled 10 dp dot, on a 180 dp tall canvas.
class _RadarGraphic extends StatelessWidget {
  final Color color;

  const _RadarGraphic({required this.color});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 180,
      width: double.infinity,
      child: CustomPaint(painter: _RadarPainter(color)),
    );
  }
}

class _RadarPainter extends CustomPainter {
  final Color color;

  _RadarPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final ring = Paint()
      ..color = color.withValues(alpha: .16)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final radius in const [90.0, 65.0, 40.0]) {
      canvas.drawCircle(center, radius, ring);
    }
    canvas.drawCircle(center, 10, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_RadarPainter oldDelegate) => oldDelegate.color != color;
}

/// Kotlin's nearby row: a plain card with the emoji, title, place,
/// "Difficulty · duration", a Sponsored pill and the distance on the right.
class _NearbyCard extends StatelessWidget {
  final Quest quest;

  /// Only set when a real distance is known.
  final String? distanceLabel;
  final VoidCallback onTap;

  const _NearbyCard({required this.quest, this.distanceLabel, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Text(quest.emoji ?? '🎯', style: textTheme.titleLarge),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(quest.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: textTheme.titleSmall),
                    const SizedBox(height: 4),
                    Text(
                      quest.locationName ?? 'Location not specified',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodySmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${_difficultyLabel(quest.difficulty)} · ${quest.durationMinutes} min',
                      style: textTheme.bodySmall,
                    ),
                    if (quest.isSponsored) ...[const SizedBox(height: 4), const SponsoredBadge()],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Text(distanceLabel ?? 'Distance unavailable', style: textTheme.labelSmall),
            ],
          ),
        ),
      ),
    );
  }
}

String _difficultyLabel(String difficulty) => switch (difficulty) {
  'easy' => 'Easy',
  'medium' => 'Medium',
  'hard' => 'Hard',
  _ => difficulty,
};
