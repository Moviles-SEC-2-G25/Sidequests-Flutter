import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
import '../../core/category_labels.dart';
import '../../models/quest.dart';
import '../../models/quest_recommendation.dart';
import '../../viewmodel/profile/profile_view_model.dart';
import '../../viewmodel/quests/quest_view_model.dart';
import 'mission_tab_view.dart';
import 'quest_detail_view.dart';

/// The "Explorar" tab: greeting, time/scope filters, a "continue where you
/// left off" banner, AI-personalized recommendations (backed by the shared
/// `recommend_quests` RPC / BQ5), and the full filterable catalogue below.
class ExploreView extends StatefulWidget {
  const ExploreView({super.key});

  @override
  State<ExploreView> createState() => _ExploreViewState();
}

class _ExploreViewState extends State<ExploreView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadAll());
  }

  Future<void> _loadAll() async {
    final questViewModel = context.read<QuestViewModel>();
    final profileViewModel = context.read<ProfileViewModel>();
    await Future.wait([questViewModel.load(), profileViewModel.load()]);
    if (!mounted) return;
    await questViewModel.loadRecommendations(profileViewModel.preferences);
  }

  String get _greeting {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Buenos días';
    if (hour < 19) return 'Buenas tardes';
    return 'Buenas noches';
  }

  @override
  Widget build(BuildContext context) {
    final questViewModel = context.watch<QuestViewModel>();
    final profileViewModel = context.watch<ProfileViewModel>();

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _loadAll,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
            children: [
              _Header(greeting: _greeting, displayName: profileViewModel.profile?.displayName),
              const SizedBox(height: 20),
              _TimeAndScopeFilters(questViewModel: questViewModel, profileViewModel: profileViewModel),
              if (questViewModel.currentMission != null) ...[
                const SizedBox(height: 16),
                _ContinueBanner(userQuestId: questViewModel.currentMission!.questId),
              ],
              const SizedBox(height: 20),
              _RecommendedSection(questViewModel: questViewModel, profileViewModel: profileViewModel),
              const SizedBox(height: 24),
              _AllMissionsSection(questViewModel: questViewModel),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String greeting;
  final String? displayName;

  const _Header({required this.greeting, this.displayName});

  @override
  Widget build(BuildContext context) {
    final initials = (displayName?.isNotEmpty ?? false) ? displayName![0].toUpperCase() : '🙂';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('$greeting 👋', style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 4),
              Text('¿Qué te apetece hoy?', style: Theme.of(context).textTheme.headlineSmall),
            ],
          ),
        ),
        CircleAvatar(
          radius: 24,
          backgroundColor: AppColors.primaryContainerLight,
          child: Text(initials, style: const TextStyle(fontWeight: FontWeight.bold)),
        ),
      ],
    );
  }
}

class _TimeAndScopeFilters extends StatelessWidget {
  final QuestViewModel questViewModel;
  final ProfileViewModel profileViewModel;

  const _TimeAndScopeFilters({required this.questViewModel, required this.profileViewModel});

  static const _minuteLabels = {10: '10m', 20: '20m', 30: '30m', 45: '45m', 60: '1 hr+'};
  static const _scopes = [
    ('all', '🌐 Todas'),
    ('gps', '📍 Cerca'),
    ('anywhere', '🏠 Donde sea'),
  ];

  void _reload() => questViewModel.loadRecommendations(profileViewModel.preferences);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'TENGO...',
          style: Theme.of(
            context,
          ).textTheme.labelMedium?.copyWith(letterSpacing: 1, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 40,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: kAvailableMinuteOptions.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final minutes = kAvailableMinuteOptions[index];
              final selected = questViewModel.selectedMinutes == minutes;
              return ChoiceChip(
                label: Text(_minuteLabels[minutes] ?? '$minutes m'),
                selected: selected,
                onSelected: (_) {
                  questViewModel.setMinutes(minutes);
                  _reload();
                },
              );
            },
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: _scopes.map((entry) {
            final (value, label) = entry;
            final selected = questViewModel.selectedLocationScope == value;
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(label),
                selected: selected,
                selectedColor: AppColors.amber,
                onSelected: (_) {
                  questViewModel.setLocationScope(value);
                  _reload();
                },
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}

class _ContinueBanner extends StatelessWidget {
  final String userQuestId;

  const _ContinueBanner({required this.userQuestId});

  @override
  Widget build(BuildContext context) {
    final quest = context.watch<QuestViewModel>().questById(userQuestId);
    if (quest == null) return const SizedBox.shrink();

    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const MissionTabView(isTab: false)),
      ),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [AppColors.primary, AppColors.primaryLight],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'CONTINÚA DONDE LO DEJASTE',
                    style: TextStyle(
                      color: Colors.white70,
                      fontWeight: FontWeight.w700,
                      fontSize: 11,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${quest.emoji ?? '🎯'}  ${quest.title}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward, color: Colors.white),
          ],
        ),
      ),
    );
  }
}

class _RecommendedSection extends StatelessWidget {
  final QuestViewModel questViewModel;
  final ProfileViewModel profileViewModel;

  const _RecommendedSection({required this.questViewModel, required this.profileViewModel});

  @override
  Widget build(BuildContext context) {
    if (questViewModel.isLoadingRecommendations && questViewModel.recommendations.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (questViewModel.recommendations.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Recomendados para ti', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.primary,
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Text(
                'ANÁLISIS',
                style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Basado en tu tiempo, intereses y historial',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        ...questViewModel.recommendations.asMap().entries.map((entry) {
          final index = entry.key;
          final recommendation = entry.value;
          final quest = questViewModel.questById(recommendation.questId);
          if (quest == null) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _RecommendationCard(
              rank: index + 1,
              quest: quest,
              recommendation: recommendation,
              onDismiss: () =>
                  questViewModel.skipRecommendation(quest.id, profileViewModel.preferences),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => QuestDetailView(quest: quest, wasRecommended: true)),
              ),
            ),
          );
        }),
      ],
    );
  }
}

class _RecommendationCard extends StatelessWidget {
  final int rank;
  final Quest quest;
  final QuestRecommendation recommendation;
  final VoidCallback onDismiss;
  final VoidCallback onTap;

  const _RecommendationCard({
    required this.rank,
    required this.quest,
    required this.recommendation,
    required this.onDismiss,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final reasons = <String>[
      if (recommendation.timeMatch) 'Encaja en tu tiempo',
      if (recommendation.interestMatch) 'Coincide con tus intereses',
      if (recommendation.locationMatch) 'Cerca de ti',
      if (recommendation.socialMatch) 'Ideal para ti',
    ];

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Ink(
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppColors.primary.withValues(alpha: 0.12)),
        ),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _Badge(text: '#$rank para ti', color: AppColors.primaryContainerLight),
                const SizedBox(width: 6),
                if (quest.isNew) _Badge(text: 'NUEVO', color: AppColors.amber, textColor: Colors.white),
                const Spacer(),
                _DifficultyBadge(difficulty: quest.difficulty),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(quest.emoji ?? '🎯', style: const TextStyle(fontSize: 28)),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(quest.title, style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 4),
                      Text(
                        quest.description,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                _MetaItem(icon: Icons.access_time, label: '${quest.durationMinutes} min'),
                _MetaItem(
                  icon: Icons.payments_outlined,
                  label: quest.estimatedCost > 0 ? '\$${quest.estimatedCost.toStringAsFixed(0)}' : 'Gratis',
                ),
                _MetaItem(
                  icon: Icons.location_on_outlined,
                  label: quest.locationMode == 'anywhere' ? 'Donde sea' : 'Cerca',
                ),
              ],
            ),
            if (reasons.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: reasons
                    .map(
                      (reason) => _Badge(
                        text: reason,
                        color: AppColors.secondaryContainerLight,
                        textColor: AppColors.secondaryDark,
                      ),
                    )
                    .toList(),
              ),
            ],
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton(
                onPressed: onDismiss,
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 36)),
                child: const Text('Ahora no →'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AllMissionsSection extends StatelessWidget {
  final QuestViewModel questViewModel;

  const _AllMissionsSection({required this.questViewModel});

  @override
  Widget build(BuildContext context) {
    if (questViewModel.isLoading && questViewModel.catalog.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (questViewModel.errorMessage != null && questViewModel.catalog.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(child: Text(questViewModel.errorMessage!)),
      );
    }

    final categoryOptions = [null, 'sponsored', ...questViewModel.categories];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 40,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: categoryOptions.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final value = categoryOptions[index];
              final label = value == null
                  ? 'Todo'
                  : value == 'sponsored'
                  ? '⭐ Patrocinadas'
                  : categoryLabelEs(value);
              final selected = questViewModel.selectedCategory == value;
              return ChoiceChip(
                label: Text(label),
                selected: selected,
                onSelected: (_) => questViewModel.setCategory(value),
              );
            },
          ),
        ),
        const SizedBox(height: 16),
        Text('Todas las misiones', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        if (questViewModel.filteredCatalog.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text('No hay misiones que coincidan con estos filtros.'),
          )
        else
          ...questViewModel.filteredCatalog.map(
            (quest) => _QuestRow(
              quest: quest,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => QuestDetailView(quest: quest)),
              ),
            ),
          ),
      ],
    );
  }
}

class _QuestRow extends StatelessWidget {
  final Quest quest;
  final VoidCallback onTap;

  const _QuestRow({required this.quest, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        onTap: onTap,
        leading: Text(quest.emoji ?? '🎯', style: const TextStyle(fontSize: 24)),
        title: Text(quest.title, style: Theme.of(context).textTheme.titleSmall),
        subtitle: Text(
          '${quest.durationMinutes} min · ${quest.estimatedCost > 0 ? '-\$${quest.estimatedCost.toStringAsFixed(0)}' : 'Gratis'} · ${_difficultyLabel(quest.difficulty)}',
        ),
        trailing: const Icon(Icons.chevron_right),
      ),
    );
  }
}

class _MetaItem extends StatelessWidget {
  final IconData icon;
  final String label;

  const _MetaItem({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: Theme.of(context).colorScheme.outline),
        const SizedBox(width: 4),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

class _Badge extends StatelessWidget {
  final String text;
  final Color color;
  final Color? textColor;

  const _Badge({required this.text, required this.color, this.textColor});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(20)),
      child: Text(
        text,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: textColor),
      ),
    );
  }
}

class _DifficultyBadge extends StatelessWidget {
  final String difficulty;

  const _DifficultyBadge({required this.difficulty});

  @override
  Widget build(BuildContext context) {
    return _Badge(
      text: _difficultyLabel(difficulty),
      color: AppColors.secondaryContainerLight,
      textColor: AppColors.secondaryDark,
    );
  }
}

String _difficultyLabel(String difficulty) => switch (difficulty) {
  'easy' => 'Fácil',
  'medium' => 'Media',
  'hard' => 'Difícil',
  _ => difficulty,
};
