import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
import '../../models/user_quest.dart';
import '../../viewmodel/quests/quest_view_model.dart';
import 'explore_view.dart';

/// "Exit mission" confirmation. Leaving here does not throw progress away —
/// `current_step`/`completed_steps` are already persisted — it records an
/// optional reason (BQ6: quest abandonment reasons) via the same
/// `abandonQuest` used everywhere else, and the quest stays resumable from
/// the Explore "continue" banner / Misión tab afterwards.
class AbandonMissionView extends StatefulWidget {
  final UserQuest mission;
  final int totalSteps;

  const AbandonMissionView({super.key, required this.mission, required this.totalSteps});

  @override
  State<AbandonMissionView> createState() => _AbandonMissionViewState();
}

class _AbandonMissionViewState extends State<AbandonMissionView> {
  static const _reasons = [
    ('ran_out_of_time', '⏰', 'Se me acabó el tiempo'),
    ('place_closed', '🔒', 'El lugar estaba cerrado'),
  ];

  String? _selectedReason;
  bool _isSaving = false;

  Future<void> _leave() async {
    setState(() => _isSaving = true);
    final questViewModel = context.read<QuestViewModel>();
    await questViewModel.abandonQuest(widget.mission, reason: _selectedReason ?? 'not_specified');
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const ExploreView()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final quest = context.watch<QuestViewModel>().questById(widget.mission.questId);
    final completed = widget.mission.completedSteps.length;
    final progress = widget.totalSteps > 0 ? completed / widget.totalSteps : 0.0;

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(quest?.emoji ?? '🌿', style: const TextStyle(fontSize: 32)),
              const SizedBox(height: 12),
              Text('¿Necesitas un descanso? Está bien.', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(
                'Tu progreso está guardado. Vuelve cuando quieras — sin límite de tiempo.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 20),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.15),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'DÓNDE LO DEJASTE',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(letterSpacing: 0.5),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Text(quest?.emoji ?? '🎯', style: const TextStyle(fontSize: 20)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            quest?.title ?? '',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                        ),
                      ],
                    ),
                    if (widget.totalSteps > 0) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Pausado en el paso ${widget.mission.currentStep + 1}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 10),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 6,
                          backgroundColor: AppColors.primaryContainerLight,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '$completed de ${widget.totalSteps} pasos completados',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          Text(
                            '${(progress * 100).round()}%',
                            style: const TextStyle(
                              color: AppColors.secondaryDark,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Text(
                '¿Qué pasó? (opcional — nos ayuda a mejorar)',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 10),
              ..._reasons.map((entry) {
                final (value, emoji, label) = entry;
                final selected = _selectedReason == value;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => setState(() => _selectedReason = selected ? null : value),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: selected ? AppColors.primaryContainerLight : Theme.of(context).cardColor,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: selected
                              ? AppColors.primary
                              : Theme.of(context).colorScheme.outline.withValues(alpha: 0.15),
                        ),
                      ),
                      child: Row(
                        children: [
                          Text(emoji, style: const TextStyle(fontSize: 18)),
                          const SizedBox(width: 10),
                          Text(label),
                        ],
                      ),
                    ),
                  ),
                );
              }),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _isSaving ? null : _leave,
                child: _isSaving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('Guardar y volver después'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: _isSaving ? null : _leave,
                child: const Text('Empezar otra misión'),
              ),
              const SizedBox(height: 8),
              Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Mejor sigamos →'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
