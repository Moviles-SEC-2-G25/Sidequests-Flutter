import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
import '../../core/distance.dart';
import '../../models/quest.dart';
import '../../viewmodel/quests/quest_view_model.dart';
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

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: questViewModel.load,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
            children: [
              Text(
                'MISIONES DE UBICACIÓN',
                style: Theme.of(
                  context,
                ).textTheme.labelMedium?.copyWith(color: AppColors.primary, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text('¿A dónde vas hoy?', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 6),
              Text(
                '${gpsQuests.length} lugares esperando — confirmados con 📷 + 📍',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 24),
              const _RadarGraphic(),
              const SizedBox(height: 20),
              if (questViewModel.userLatitude == null)
                FilledButton(
                  onPressed: questViewModel.isLocatingUser
                      ? null
                      : questViewModel.requestUserLocation,
                  child: questViewModel.isLocatingUser
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('Activar ubicación para ver distancias'),
                ),
              const SizedBox(height: 20),
              Text(
                'DISPONIBLES · ${gpsQuests.length}',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(letterSpacing: 0.5),
              ),
              const SizedBox(height: 10),
              for (final (quest, distanceKm) in withDistance)
                _NearbyCard(
                  quest: quest,
                  distanceLabel: '${distanceKm.toStringAsFixed(1)} km',
                  onTap: () => Navigator.of(
                    context,
                  ).push(MaterialPageRoute(builder: (_) => QuestDetailView(quest: quest))),
                ),
              for (final quest in withoutDistance)
                _NearbyCard(
                  quest: quest,
                  onTap: () => Navigator.of(
                    context,
                  ).push(MaterialPageRoute(builder: (_) => QuestDetailView(quest: quest))),
                ),
            ],
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

class _RadarGraphic extends StatelessWidget {
  const _RadarGraphic();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 180,
      child: Center(
        child: Stack(
          alignment: Alignment.center,
          children: [
            for (final size in [180.0, 130.0, 80.0])
              Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.primary.withValues(alpha: 0.15)),
                ),
              ),
            Container(
              width: 20,
              height: 20,
              decoration: const BoxDecoration(color: AppColors.primary, shape: BoxShape.circle),
              child: const Icon(Icons.location_on, size: 14, color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}

class _NearbyCard extends StatelessWidget {
  final Quest quest;

  /// Only set when a real distance is known; the location name always lives
  /// under the title so long names can't squeeze the title column.
  final String? distanceLabel;
  final VoidCallback onTap;

  const _NearbyCard({required this.quest, this.distanceLabel, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final bodySmall = Theme.of(context).textTheme.bodySmall;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: AppColors.primaryContainerLight,
                child: Text(quest.emoji ?? '🎯'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      quest.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        const Icon(Icons.location_on_outlined, size: 14, color: AppColors.primary),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            quest.locationName ?? 'Ubicación no especificada',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: bodySmall,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Wrap(
                      spacing: 8,
                      children: [
                        Text(_difficultyLabel(quest.difficulty), style: bodySmall),
                        Text('${quest.durationMinutes} min', style: bodySmall),
                      ],
                    ),
                  ],
                ),
              ),
              if (distanceLabel != null) ...[
                const SizedBox(width: 8),
                Text(distanceLabel!, style: bodySmall?.copyWith(fontWeight: FontWeight.w600)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

String _difficultyLabel(String difficulty) => switch (difficulty) {
  'easy' => 'Fácil',
  'medium' => 'Media',
  'hard' => 'Difícil',
  _ => difficulty,
};
