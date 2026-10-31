import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
import '../../models/abandonment_reason.dart';
import '../../models/user_quest.dart';
import '../../viewmodel/profile/profile_view_model.dart';
import '../../viewmodel/quests/quest_view_model.dart';
import 'quest_alternatives_view.dart';

/// "Exit mission" confirmation. "Guardar y volver después" just goes back: the
/// progress is already persisted and the mission stays active. "Empezar otra
/// misión" abandons it, with an optional reason (BQ6: quest abandonment
/// reasons), and offers alternatives.
class AbandonMissionView extends StatefulWidget {
  final UserQuest mission;
  final int totalSteps;

  const AbandonMissionView({super.key, required this.mission, required this.totalSteps});

  @override
  State<AbandonMissionView> createState() => _AbandonMissionViewState();
}

class _AbandonMissionViewState extends State<AbandonMissionView> {
  AbandonmentReason? _selectedReason;
  bool _isSaving = false;

  Future<void> _abandon() async {
    setState(() => _isSaving = true);
    final questViewModel = context.read<QuestViewModel>();
    final saved = await questViewModel.abandonQuest(
      widget.mission,
      reason: _selectedReason ?? AbandonmentReason.other,
      preferences: context.read<ProfileViewModel>().preferences,
    );
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (!saved) {
      // Couldn't even be kept on the device: stay, so the user can retry or go on.
      setState(() => _isSaving = false);
      messenger.showSnackBar(
        SnackBar(content: Text(questViewModel.errorMessage ?? 'No se pudo guardar.')),
      );
      return;
    }
    if (questViewModel.abandonmentQueued) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Misión abandonada sin conexión: se sincronizará al reconectar.')),
      );
    }
    final navigator = Navigator.of(context);
    if (questViewModel.questAlternatives == null) {
      // It was already abandoned: nothing new to suggest.
      questViewModel.requestExploreTab();
      navigator.popUntil((route) => route.isFirst);
      return;
    }
    // Keeps the first route, the one under AuthGate with HomeShell: back from
    // the alternatives lands there, and logging out still reaches the login.
    navigator.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const QuestAlternativesView()),
      (route) => route.isFirst,
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
                'Si guardas, tu progreso te espera: vuelve cuando quieras, sin límite de tiempo. '
                'Si empiezas otra misión, esta quedará abandonada.',
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
                'Si la dejas, ¿qué pasó? (opcional — nos ayuda a mejorar)',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 10),
              ...AbandonmentReason.values.map((reason) {
                final selected = _selectedReason == reason;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => setState(() => _selectedReason = selected ? null : reason),
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
                          Text(reason.emoji, style: const TextStyle(fontSize: 18)),
                          const SizedBox(width: 10),
                          Expanded(child: Text(reason.label)),
                        ],
                      ),
                    ),
                  ),
                );
              }),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _isSaving ? null : () => Navigator.of(context).pop(),
                child: const Text('Guardar y volver después'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: _isSaving ? null : _abandon,
                child: _isSaving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Empezar otra misión'),
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
