import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
import '../../core/category_labels.dart';
import '../../models/quest.dart';
import '../../models/user_quest.dart';
import '../../viewmodel/quests/quest_view_model.dart';
import 'mission_tab_view.dart';

/// Quest detail: full info, a 2x2 stat grid, difficulty banner, step count
/// and the accept CTA — or, if the quest is already in progress/completed,
/// the matching state instead of a duplicate "accept" action.
class QuestDetailView extends StatefulWidget {
  final Quest quest;
  final bool wasRecommended;

  const QuestDetailView({super.key, required this.quest, this.wasRecommended = false});

  @override
  State<QuestDetailView> createState() => _QuestDetailViewState();
}

class _QuestDetailViewState extends State<QuestDetailView> {
  bool _isAccepting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => context.read<QuestViewModel>().loadSteps(widget.quest.id),
    );
  }

  Future<void> _accept() async {
    setState(() => _isAccepting = true);
    final questViewModel = context.read<QuestViewModel>();
    await questViewModel.acceptQuest(widget.quest.id, wasRecommended: widget.wasRecommended);
    if (!mounted) return;
    Navigator.of(
      context,
    ).pushReplacement(MaterialPageRoute(builder: (_) => const MissionTabView(isTab: false)));
  }

  @override
  Widget build(BuildContext context) {
    final quest = widget.quest;
    final questViewModel = context.watch<QuestViewModel>();
    final UserQuest? userQuest = questViewModel.userQuests
        .cast<UserQuest?>()
        .firstWhere((uq) => uq?.questId == quest.id, orElse: () => null);
    final isUnfinished =
        userQuest != null && userQuest.status != 'completed' && userQuest.status != 'skipped';
    final isCompleted = userQuest?.status == 'completed';
    final stepsForThisQuest = questViewModel.steps;
    final stepCount = stepsForThisQuest.isNotEmpty ? stepsForThisQuest.length : null;

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                backgroundColor: Theme.of(context).cardColor,
                child: IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  if (quest.isNew) _pill('NUEVO', AppColors.amber, Colors.white),
                  if (quest.isNew) const SizedBox(width: 8),
                  Text(
                    categoryLabelEs(quest.category).toUpperCase(),
                    style: Theme.of(
                      context,
                    ).textTheme.labelMedium?.copyWith(color: Theme.of(context).colorScheme.outline),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(quest.emoji ?? '🎯', style: const TextStyle(fontSize: 36)),
              const SizedBox(height: 8),
              Text(quest.title, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 12),
              Text(quest.description, style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 20),
              GridView.count(
                crossAxisCount: 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 2.2,
                children: [
                  _StatCard(
                    icon: Icons.access_time,
                    label: 'DURACIÓN',
                    value: '${quest.durationMinutes} min',
                  ),
                  _StatCard(
                    icon: Icons.payments_outlined,
                    label: 'COSTO APROX.',
                    value: quest.estimatedCost > 0
                        ? '\$${quest.estimatedCost.toStringAsFixed(0)}'
                        : 'Gratis',
                  ),
                  _StatCard(
                    icon: Icons.location_on_outlined,
                    label: 'UBICACIÓN',
                    value: quest.locationMode == 'anywhere' ? 'Donde sea' : 'Cerca',
                  ),
                  _StatCard(
                    icon: Icons.people_outline,
                    label: 'SOCIAL',
                    value: _socialLabel(quest.socialLevel),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.secondaryContainerLight,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.eco_outlined, color: AppColors.secondaryDark),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Dificultad: ${_difficultyLabel(quest.difficulty)}',
                            style: const TextStyle(
                              color: AppColors.secondaryDark,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            quest.difficulty == 'easy'
                                ? 'Sin planificación, empieza ya'
                                : 'Un poco de preparación puede ayudar',
                            style: const TextStyle(color: AppColors.secondaryDark, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Text(
                stepCount != null ? 'Qué harás ($stepCount pasos)' : 'Qué harás',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 24),
              if (isCompleted)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.secondaryContainerLight,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Text(
                    '✓ Ya completaste esta misión',
                    style: TextStyle(color: AppColors.secondaryDark, fontWeight: FontWeight.w700),
                  ),
                )
              else if (isUnfinished)
                FilledButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const MissionTabView(isTab: false)),
                  ),
                  child: const Text('Continuar misión →'),
                )
              else
                FilledButton(
                  onPressed: _isAccepting ? null : _accept,
                  child: _isAccepting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('Aceptar misión →'),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pill(String text, Color color, Color textColor) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(20)),
    child: Text(text, style: TextStyle(color: textColor, fontWeight: FontWeight.w700, fontSize: 11)),
  );
}

class _StatCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _StatCard({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.15)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: Theme.of(context).colorScheme.outline),
              const SizedBox(width: 4),
              Text(
                label,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(letterSpacing: 0.5),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(value, style: Theme.of(context).textTheme.titleSmall),
        ],
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

String _socialLabel(String socialLevel) => switch (socialLevel) {
  'solo' => 'Individual — solo tú',
  'social' => 'Social — con otros',
  'group' => 'Grupal',
  _ => socialLevel,
};
