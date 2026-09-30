import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
import '../../core/category_labels.dart';
import '../../models/quest_step.dart';
import '../../models/user_quest.dart';
import '../../viewmodel/quests/quest_view_model.dart';
import 'abandon_mission_view.dart';
import 'explore_view.dart';
import 'quest_completed_view.dart';

/// The "Misión" tab: the current in-progress (or paused/abandoned-but-
/// resumable) quest's step checklist. Also reachable as a pushed full
/// screen (`isTab: false`) from the Explore "continue" banner and from
/// Quest Detail's "Continuar misión".
class MissionTabView extends StatefulWidget {
  final bool isTab;

  const MissionTabView({super.key, this.isTab = true});

  @override
  State<MissionTabView> createState() => _MissionTabViewState();
}

class _MissionTabViewState extends State<MissionTabView> {
  String? _loadedForQuestId;

  void _ensureStepsLoaded(QuestViewModel questViewModel) {
    final mission = questViewModel.currentMission;
    if (mission == null || _loadedForQuestId == mission.questId) return;
    _loadedForQuestId = mission.questId;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => questViewModel.loadSteps(mission.questId),
    );
  }

  @override
  Widget build(BuildContext context) {
    final questViewModel = context.watch<QuestViewModel>();
    _ensureStepsLoaded(questViewModel);
    final mission = questViewModel.currentMission;
    final quest = mission == null ? null : questViewModel.questById(mission.questId);

    return Scaffold(
      appBar: !widget.isTab
          ? AppBar(
              leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => Navigator.of(context).pop(),
              ),
            )
          : null,
      body: SafeArea(
        child: mission == null || quest == null
            ? const _NoMissionState()
            : _MissionChecklist(mission: mission, quest: quest, questViewModel: questViewModel),
      ),
    );
  }
}

class _NoMissionState extends StatelessWidget {
  const _NoMissionState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('⚡', style: TextStyle(fontSize: 48)),
            const SizedBox(height: 16),
            Text('No tienes ninguna misión activa', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Acepta una misión desde Explorar o Cerca para empezar.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () => Navigator.of(
                context,
              ).pushReplacement(MaterialPageRoute(builder: (_) => const ExploreView())),
              child: const Text('Explorar misiones'),
            ),
          ],
        ),
      ),
    );
  }
}

class _MissionChecklist extends StatelessWidget {
  final UserQuest mission;
  final dynamic quest;
  final QuestViewModel questViewModel;

  const _MissionChecklist({
    required this.mission,
    required this.quest,
    required this.questViewModel,
  });

  @override
  Widget build(BuildContext context) {
    if (questViewModel.isLoadingSteps && questViewModel.steps.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    final steps = questViewModel.steps;
    final completed = mission.completedSteps.toSet();
    final currentIndex = mission.currentStep;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Text(quest.emoji ?? '🎯', style: const TextStyle(fontSize: 24)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            categoryLabelEs(quest.category).toUpperCase(),
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                          Text(quest.title, style: Theme.of(context).textTheme.titleMedium),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              OutlinedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => AbandonMissionView(mission: mission, totalSteps: steps.length),
                  ),
                ),
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 36)),
                child: const Text('Salir'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (steps.isNotEmpty) ...[
            Row(
              children: List.generate(steps.length, (index) {
                final isDone = completed.contains(index);
                final isCurrent = index == currentIndex;
                return Expanded(
                  child: Container(
                    height: 6,
                    margin: EdgeInsets.only(right: index == steps.length - 1 ? 0 : 4),
                    decoration: BoxDecoration(
                      color: isDone
                          ? AppColors.secondary
                          : isCurrent
                          ? AppColors.primary
                          : AppColors.primaryContainerLight,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                );
              }),
            ),
            const SizedBox(height: 8),
            Text(
              '${completed.length} de ${steps.length} pasos completados',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            for (var i = 0; i < steps.length; i++)
              _StepTile(
                step: steps[i],
                index: i,
                isDone: completed.contains(i),
                isCurrent: i == currentIndex,
              ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: currentIndex < steps.length
                  ? () async {
                      final navigator = Navigator.of(context);
                      final completedMission = await questViewModel.completeCurrentStep(mission);
                      if (!completedMission || !navigator.mounted) return;
                      navigator.push(
                        MaterialPageRoute(
                          builder: (_) => QuestCompletedView(mission: mission, quest: quest),
                        ),
                      );
                    }
                  : null,
              child: Text(
                currentIndex >= steps.length - 1 ? 'Completar misión →' : 'Completar este paso →',
              ),
            ),
          ] else
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text('Esta misión no tiene pasos definidos.'),
            ),
        ],
      ),
    );
  }
}

class _StepTile extends StatelessWidget {
  final QuestStep step;
  final int index;
  final bool isDone;
  final bool isCurrent;

  const _StepTile({
    required this.step,
    required this.index,
    required this.isDone,
    required this.isCurrent,
  });

  bool get _needsPhoto =>
      step.verificationType == 'photo' || step.verificationType == 'photo_and_location';
  bool get _needsLocation =>
      step.verificationType == 'location' || step.verificationType == 'photo_and_location';

  @override
  Widget build(BuildContext context) {
    final textColor = isDone ? AppColors.secondaryDark : null;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDone
            ? AppColors.secondaryContainerLight
            : isCurrent
            ? Theme.of(context).cardColor
            : Theme.of(context).cardColor.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
        border: isCurrent ? Border.all(color: AppColors.primary, width: 2) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 12,
                backgroundColor: isDone
                    ? AppColors.secondary
                    : isCurrent
                    ? AppColors.primary
                    : Theme.of(context).colorScheme.outline.withValues(alpha: 0.3),
                child: isDone
                    ? const Icon(Icons.check, size: 14, color: Colors.white)
                    : Text(
                        '${index + 1}',
                        style: const TextStyle(color: Colors.white, fontSize: 12),
                      ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      step.title,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: textColor,
                        decoration: isDone ? TextDecoration.lineThrough : null,
                        fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                    if (isCurrent && step.description.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(step.description, style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (isCurrent && (_needsPhoto || _needsLocation)) ...[
            const SizedBox(height: 12),
            if (_needsPhoto) _VerificationRow(icon: Icons.camera_alt_outlined, label: 'Foto de verificación'),
            if (_needsLocation) _VerificationRow(icon: Icons.location_on_outlined, label: 'Coordenadas GPS'),
          ],
        ],
      ),
    );
  }
}

/// Verification capture is rendered but disabled: Sidequests-Backend has no
/// Storage bucket yet (photo proof has nowhere to upload to) and
/// `user_quests` has no per-step location-verification column, so this
/// can't be wired to anything real yet without fabricating a fake success.
class _VerificationRow extends StatelessWidget {
  final IconData icon;
  final String label;

  const _VerificationRow({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, color: Theme.of(context).colorScheme.outline),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: Theme.of(context).textTheme.bodySmall),
                Text(
                  'Aún no disponible en el backend',
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(color: Theme.of(context).colorScheme.outline),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          const _DisabledPill(),
        ],
      ),
    );
  }
}

class _DisabledPill extends StatelessWidget {
  const _DisabledPill();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        'Próximamente',
        style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.outline),
      ),
    );
  }
}
