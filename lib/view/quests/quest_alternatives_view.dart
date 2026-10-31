import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
import '../../core/quest_alternative_recommender.dart';
import '../../viewmodel/profile/profile_view_model.dart';
import '../../viewmodel/quests/quest_view_model.dart';
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
                      Text('Una mejor opción para ahora', style: textTheme.headlineSmall),
                      const SizedBox(height: 8),
                      Text(
                        'La dejaste porque: ${state.reason.label}',
                        style: textTheme.bodyMedium,
                      ),
                      if (state.context != null) ...[
                        const SizedBox(height: 4),
                        Text(_contextLine(state), style: textTheme.bodySmall),
                      ],
                      if (state.context != null && state.weatherCondition == 'unknown') ...[
                        const SizedBox(height: 4),
                        Text(
                          'No conocemos el clima actual, así que las sugerencias no lo tienen en cuenta.',
                          style: textTheme.bodySmall,
                        ),
                      ],
                      const SizedBox(height: 20),
                      if (state.isLoading)
                        const Padding(
                          padding: EdgeInsets.all(32),
                          child: Center(child: CircularProgressIndicator()),
                        )
                      else if (state.suggestions.isEmpty)
                        Text(
                          'Ahora no hay misiones que encajen mejor. Puedes buscar otra en Explorar.',
                          style: textTheme.bodyMedium,
                        )
                      else
                        ...state.suggestions.map(
                          (alternative) => _AlternativeCard(
                            alternative: alternative,
                            onOpen: () => _open(alternative),
                          ),
                        ),
                      const SizedBox(height: 12),
                      OutlinedButton(
                        onPressed: state.isLoading
                            ? null
                            : () => context.read<QuestViewModel>().refreshQuestAlternatives(
                                context.read<ProfileViewModel>().preferences,
                              ),
                        child: const Text('Actualizar sugerencias'),
                      ),
                      const SizedBox(height: 8),
                      TextButton(onPressed: _leave, child: const Text('Volver a Explorar')),
                    ],
                  ),
                ),
        ),
      ),
    );
  }

  String _contextLine(QuestAlternativesState state) {
    final time = switch (state.context!.timeOfDay) {
      'morning' => 'Mañana',
      'afternoon' => 'Tarde',
      'evening' => 'Atardecer',
      _ => 'Noche',
    };
    final weather = switch (state.weatherCondition) {
      'clear' => 'Despejado',
      'cloudy' => 'Nublado',
      'rain' => 'Lluvia',
      'snow' => 'Nieve',
      'storm' => 'Tormenta',
      _ => 'Clima desconocido',
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
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.15)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(quest.emoji ?? '🎯', style: const TextStyle(fontSize: 22)),
              const SizedBox(width: 8),
              Expanded(child: Text(quest.title, style: textTheme.titleSmall)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${quest.durationMinutes} min · '
            '${quest.estimatedCost > 0 ? '\$${quest.estimatedCost.toStringAsFixed(0)}' : 'Gratis'}',
            style: textTheme.bodySmall,
          ),
          const SizedBox(height: 10),
          Text(
            'Por qué te sirve',
            style: textTheme.labelMedium?.copyWith(color: AppColors.secondaryDark),
          ),
          const SizedBox(height: 4),
          ...alternative.explanations.map(
            (explanation) => Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text('• $explanation', style: textTheme.bodySmall),
            ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(onPressed: onOpen, child: const Text('Ver misión')),
          ),
        ],
      ),
    );
  }
}
