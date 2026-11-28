import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
import '../../core/quest_alternative_recommender.dart';
import '../../viewmodel/profile/profile_view_model.dart';
import '../../viewmodel/quests/quest_view_model.dart';
import '../widgets/sponsored_badge.dart';
import 'quest_detail_view.dart';

/// Shown after abandoning a mission: up to three alternatives that fit the
/// reason and the moment, each saying why. Nothing here accepts a mission; a
/// suggestion only opens its detail.
class QuestAlternativesView extends StatefulWidget {
  const QuestAlternativesView({super.key});

  @override
  State<QuestAlternativesView> createState() => _QuestAlternativesViewState();
}

class _QuestAlternativesViewState extends State<QuestAlternativesView> {
  /// Keeps the content on screen while the route animates out, after leaving
  /// has already cleared the ViewModel's state.
  QuestAlternativesState? _lastState;

  void _leave() {
    final questViewModel = context.read<QuestViewModel>();
    questViewModel.dismissQuestAlternatives();
    questViewModel.requestExploreTab();
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  Future<void> _open(QuestAlternative alternative) async {
    final questViewModel = context.read<QuestViewModel>();
    final missionBefore = questViewModel.currentMission?.id;
    questViewModel.trackQuestAlternativeSelected(alternative);
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => QuestDetailView(quest: alternative.quest)),
    );
    // Accepted it there: these suggestions already served their purpose.
    if (mounted && questViewModel.currentMission?.id != missionBefore) _leave();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<QuestViewModel>().questAlternatives ?? _lastState;
    _lastState = state;
    final textTheme = Theme.of(context).textTheme;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        body: SafeArea(
          child: state == null
              ? const SizedBox.shrink()
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Kotlin's QuestAlternativesScreen header.
                      Text('A better fit for now', style: textTheme.headlineMedium),
                      Text(
                        'You left because: ${state.reason.label}',
                        style: textTheme.bodyMedium,
                      ),
                      Text('Choose an alternative, or return to Explore.', style: textTheme.bodyMedium),
                      if (state.context != null) ...[
                        const SizedBox(height: 4),
                        Text(_contextLine(state), style: textTheme.bodySmall),
                      ],
                      if (state.context != null && state.weatherCondition == 'unknown') ...[
                        const SizedBox(height: 4),
                        Text(
                          'The current weather is unknown, so these suggestions do not take it into account.',
                          style: textTheme.bodySmall,
                        ),
                      ],
                      const SizedBox(height: 16),
                      if (state.isLoading)
                        const Padding(
                          padding: EdgeInsets.all(32),
                          child: Center(child: CircularProgressIndicator()),
                        )
                      else if (state.suggestions.isEmpty)
                        Text(
                          'There are no better-fitting quests right now. You can find another one in Explore.',
                          style: textTheme.bodyMedium,
                        )
                      else
                        ...state.suggestions.map(
                          (alternative) => _AlternativeCard(
                            alternative: alternative,
                            onOpen: () => _open(alternative),
                          ),
                        ),
                      const SizedBox(height: 4),
                      FilledButton(
                        onPressed: state.isLoading
                            ? null
                            : () => context.read<QuestViewModel>().refreshQuestAlternatives(
                                context.read<ProfileViewModel>().preferences,
                              ),
                        child: const Text('Refresh suggestions'),
                      ),
                      const SizedBox(height: 16),
                      FilledButton(onPressed: _leave, child: const Text('Back to Explore')),
                    ],
                  ),
                ),
        ),
      ),
    );
  }

  String _contextLine(QuestAlternativesState state) {
    final time = switch (state.context!.timeOfDay) {
      'morning' => 'Morning',
      'afternoon' => 'Afternoon',
      'evening' => 'Evening',
      _ => 'Night',
    };
    final weather = switch (state.weatherCondition) {
      'clear' => 'Clear',
      'cloudy' => 'Cloudy',
      'rain' => 'Rain',
      'snow' => 'Snow',
      'storm' => 'Storm',
      _ => 'Unknown weather',
    };
    return '$time · $weather';
  }
}

class _AlternativeCard extends StatelessWidget {
  final QuestAlternative alternative;
  final VoidCallback onOpen;

  const _AlternativeCard({required this.alternative, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final quest = alternative.quest;
    final textTheme = Theme.of(context).textTheme;
    // Kotlin's alternative card: surface, 24 dp corners, 18 dp padding.
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(quest.emoji ?? '🎯', style: textTheme.titleLarge),
              const SizedBox(width: 6),
              Expanded(child: Text(quest.title, style: textTheme.titleLarge)),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${quest.durationMinutes} min · '
            '${quest.estimatedCost > 0 ? '\$${quest.estimatedCost.toStringAsFixed(0)}' : 'Free'}',
            style: textTheme.bodyLarge,
          ),
          if (quest.isSponsored) ...[
            const SizedBox(height: 6),
            const SponsoredBadge(),
          ],
          const SizedBox(height: 8),
          Text(
            'Why it works for you',
            style: textTheme.titleSmall?.copyWith(color: AppColors.secondary),
          ),
          const SizedBox(height: 8),
          ...alternative.explanations.map(
            (explanation) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('• $explanation', style: textTheme.bodyMedium),
            ),
          ),
          FilledButton(onPressed: onOpen, child: const Text('View quest')),
        ],
      ),
    );
  }
}
