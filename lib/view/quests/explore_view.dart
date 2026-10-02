import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
import '../../core/category_labels.dart';
import '../../core/completion_likelihood.dart';
import '../../models/app_context.dart';
import '../../models/quest.dart';
import '../../models/quest_recommendation.dart';
import '../../viewmodel/profile/profile_view_model.dart';
import '../../viewmodel/quests/quest_view_model.dart';
import '../widgets/completion_likelihood_label.dart';
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
            // Keyed so a conditional insertion above (the "continue" banner
            // appearing/disappearing) can't shift these to a new list slot
            // and, since ListView reconciles unkeyed children positionally,
            // silently dispose+recreate their State mid-interaction.
            children: [
              _Header(
                key: const ValueKey('header'),
                greeting: _greeting,
                displayName: profileViewModel.profile?.displayName,
              ),
              const SizedBox(height: 20),
              _TimeAndScopeFilters(
                key: const ValueKey('filters'),
                questViewModel: questViewModel,
                profileViewModel: profileViewModel,
              ),
              const SizedBox(height: 16),
              _SocialMoodFilter(
                key: const ValueKey('social-mood'),
                questViewModel: questViewModel,
                profileViewModel: profileViewModel,
              ),
              if (questViewModel.currentMission != null) ...[
                const SizedBox(height: 16),
                _ContinueBanner(
                  key: const ValueKey('continue-banner'),
                  userQuestId: questViewModel.currentMission!.questId,
                ),
              ],
              if (questViewModel.isAdaptingToContext) ...[
                const SizedBox(height: 16),
                _ContextAdaptationBanner(
                  key: const ValueKey('context-adaptation-banner'),
                  appContext: questViewModel.currentContext!,
                ),
              ],
              const SizedBox(height: 20),
              _RecommendedSection(
                key: const ValueKey('recommended'),
                questViewModel: questViewModel,
                profileViewModel: profileViewModel,
              ),
              const SizedBox(height: 24),
              _AllMissionsSection(key: const ValueKey('all-missions'), questViewModel: questViewModel),
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

  const _Header({super.key, required this.greeting, this.displayName});

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

  const _TimeAndScopeFilters({
    super.key,
    required this.questViewModel,
    required this.profileViewModel,
  });

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

/// "¿Cómo te sientes hoy?" (BQ5): overrides the profile's social level for
/// this session only and reloads recommend_quests. Starts on the profile's
/// value so the user sees what they're changing from.
class _SocialMoodFilter extends StatelessWidget {
  final QuestViewModel questViewModel;
  final ProfileViewModel profileViewModel;

  const _SocialMoodFilter({
    super.key,
    required this.questViewModel,
    required this.profileViewModel,
  });

  static const _levels = [
    ('solo', '🙋 Solo yo'),
    ('social', '👫 Con alguien'),
    ('group', '👥 En grupo'),
  ];

  @override
  Widget build(BuildContext context) {
    final current = questViewModel.effectiveSocialLevel(profileViewModel.preferences);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '¿CÓMO TE SIENTES HOY?',
          style: Theme.of(
            context,
          ).textTheme.labelMedium?.copyWith(letterSpacing: 1, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _levels.map((entry) {
            final (value, label) = entry;
            return ChoiceChip(
              label: Text(label),
              selected: current == value,
              selectedColor: AppColors.secondary,
              onSelected: (_) {
                questViewModel.setSessionSocialLevel(value);
                questViewModel.loadRecommendations(profileViewModel.preferences);
              },
            );
          }).toList(),
        ),
      ],
    );
  }
}

class _ContinueBanner extends StatelessWidget {
  final String userQuestId;

  const _ContinueBanner({super.key, required this.userQuestId});

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

/// Explains why [QuestViewModel.filteredCatalog] just reordered itself:
/// rain or nighttime pushes 'anywhere' quests first. Rain takes priority
/// over night in the message when both apply.
class _ContextAdaptationBanner extends StatelessWidget {
  final AppContext appContext;

  const _ContextAdaptationBanner({super.key, required this.appContext});

  @override
  Widget build(BuildContext context) {
    final String message;
    final IconData icon;
    if (appContext.isRainy) {
      message = 'Está lloviendo: te mostramos primero misiones bajo techo.';
      icon = Icons.umbrella_outlined;
    } else {
      message = 'Es de noche: priorizamos misiones cerca o en casa.';
      icon = Icons.nightlight_outlined;
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.primaryContainerLight,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(icon, color: AppColors.primary, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(message, style: Theme.of(context).textTheme.bodySmall)),
        ],
      ),
    );
  }
}

class _RecommendedSection extends StatelessWidget {
  final QuestViewModel questViewModel;
  final ProfileViewModel profileViewModel;

  const _RecommendedSection({super.key, required this.questViewModel, required this.profileViewModel});

  @override
  Widget build(BuildContext context) {
    if (questViewModel.isLoadingRecommendations && questViewModel.recommendations.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (questViewModel.recommendations.isEmpty) return const SizedBox.shrink();

    final likelihoodByCategory = questViewModel.completionLikelihoodByCategory;

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
              completionLevel: questViewModel.completionLevelFor(quest, likelihoodByCategory),
              onDismiss: () =>
                  questViewModel.skipRecommendation(quest.id, profileViewModel.preferences),
              onTap: () {
                questViewModel.registerInteraction();
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => QuestDetailView(quest: quest, wasRecommended: true),
                  ),
                );
              },
            ),
          );
        }),
      ],
    );
  }
}

class _RecommendationCard extends StatefulWidget {
  final int rank;
  final Quest quest;
  final QuestRecommendation recommendation;
  final CompletionLevel completionLevel;
  final VoidCallback onDismiss;
  final VoidCallback onTap;

  const _RecommendationCard({
    required this.rank,
    required this.quest,
    required this.recommendation,
    required this.completionLevel,
    required this.onDismiss,
    required this.onTap,
  });

  @override
  State<_RecommendationCard> createState() => _RecommendationCardState();
}

class _RecommendationCardState extends State<_RecommendationCard> {
  bool _isStartingInstantPlan = false;

  /// "Empezar ya" (BQ4's 'instant_plan' start path): skips QuestDetailView
  /// and goes straight to the mission checklist.
  ///
  /// Accepting the quest flips `currentMission` from null to non-null, which
  /// makes Explore's unkeyed ListView insert the "Continúa donde lo
  /// dejaste" banner right before this card's section — reshuffling this
  /// widget to a new list slot and, since it has no Key, disposing and
  /// recreating its State right under this `await`. So `navigator` and
  /// `messenger` are captured up front and used unconditionally: they're
  /// the app's long-lived Navigator/ScaffoldMessenger, not tied to this
  /// (possibly-by-then-disposed) State. Only the `setState` calls need the
  /// `mounted` guard.
  Future<void> _startInstantPlan() async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final questViewModel = context.read<QuestViewModel>();
    if (mounted) setState(() => _isStartingInstantPlan = true);
    final started = await questViewModel.startInstantPlan(widget.quest);
    if (mounted) setState(() => _isStartingInstantPlan = false);
    if (!started) {
      messenger.showSnackBar(
        SnackBar(content: Text(questViewModel.errorMessage ?? 'No se pudo iniciar la misión.')),
      );
      return;
    }
    navigator.push(MaterialPageRoute(builder: (_) => const MissionTabView(isTab: false)));
  }

  @override
  Widget build(BuildContext context) {
    final rank = widget.rank;
    final quest = widget.quest;
    final recommendation = widget.recommendation;
    final onDismiss = widget.onDismiss;
    final onTap = widget.onTap;
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
                CompletionLikelihoodLabel(level: widget.completionLevel),
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
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                OutlinedButton(
                  onPressed: _isStartingInstantPlan ? null : onDismiss,
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, 36)),
                  child: const Text('Ahora no →'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _isStartingInstantPlan ? null : _startInstantPlan,
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 36)),
                  child: _isStartingInstantPlan
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('Empezar ya →'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AllMissionsSection extends StatelessWidget {
  final QuestViewModel questViewModel;

  const _AllMissionsSection({super.key, required this.questViewModel});

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
    final likelihoodByCategory = questViewModel.completionLikelihoodByCategory;

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
              completionLevel: questViewModel.completionLevelFor(quest, likelihoodByCategory),
              onTap: () {
                questViewModel.registerInteraction();
                Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => QuestDetailView(quest: quest)));
              },
            ),
          ),
      ],
    );
  }
}

class _QuestRow extends StatelessWidget {
  final Quest quest;
  final CompletionLevel completionLevel;
  final VoidCallback onTap;

  const _QuestRow({required this.quest, required this.completionLevel, required this.onTap});

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
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CompletionLikelihoodLabel(level: completionLevel),
            const Icon(Icons.chevron_right),
          ],
        ),
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
