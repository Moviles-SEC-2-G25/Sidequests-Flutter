import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
import '../../core/category_labels.dart';
import '../../core/number_format.dart';
import '../../core/verification/step_verification_strategy.dart';
import '../../core/verification/verification_strategies.dart';
import '../../data/services/step_counter_service.dart';
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
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await questViewModel.loadSteps(mission.questId);
      // A photo taken just before Android killed the app comes back now.
      await questViewModel.recoverLostPhotoProof();
    });
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
            const SizedBox(height: 12),
            _WalkedStepsCard(mission: mission, questViewModel: questViewModel),
            const SizedBox(height: 16),
            for (var i = 0; i < steps.length; i++)
              _StepTile(
                step: steps[i],
                index: i,
                isDone: completed.contains(i),
                isCurrent: i == currentIndex,
                questViewModel: questViewModel,
                // Only the current step is being verified against live
                // evidence; one row per part of its strategy.
                verifications: i == currentIndex
                    ? [
                        for (final part in questViewModel.verificationStrategyFor(steps[i]).parts)
                          (part, questViewModel.verificationResultFor(part, quest)),
                      ]
                    : const [],
              ),
            const SizedBox(height: 12),
            FilledButton(
              // The step's strategy decides: a photo step stays blocked until
              // its proof is uploaded; location never blocks.
              onPressed:
                  currentIndex < steps.length &&
                      questViewModel.canCompleteCurrentStep(steps[currentIndex], quest)
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

/// Walked steps (podómetro) for this attempt. Says "pasos caminados" so it
/// isn't confused with the mission's checklist steps right above it. Never
/// blocks the mission: without a sensor or permission it only explains why.
class _WalkedStepsCard extends StatelessWidget {
  final UserQuest mission;
  final QuestViewModel questViewModel;

  const _WalkedStepsCard({required this.mission, required this.questViewModel});

  @override
  Widget build(BuildContext context) {
    // An abandoned attempt isn't counted until it's resumed.
    if (mission.status == 'abandoned') return const SizedBox.shrink();

    final textTheme = Theme.of(context).textTheme;
    final isThisMission = questViewModel.stepTrackedUserQuestId == mission.id;
    final steps = questViewModel.missionSteps;

    final (String title, String? subtitle, String? actionLabel) = switch (questViewModel.stepStatus) {
      StepCounterStatus.counting when isThisMission => (
        steps == null ? 'Esperando tus primeros pasos…' : '${formatThousands(steps)} pasos caminados',
        null,
        null,
      ),
      StepCounterStatus.permissionDenied => (
        'Pasos caminados',
        'Activa "Actividad física" para contarlos durante la misión.',
        'Permitir',
      ),
      StepCounterStatus.permissionPermanentlyDenied => (
        'Pasos caminados',
        'Activa "Actividad física" en los ajustes del teléfono para contarlos.',
        'Abrir ajustes',
      ),
      StepCounterStatus.unavailable => (
        'Pasos caminados',
        'Tu teléfono no tiene contador de pasos.',
        null,
      ),
      _ => ('Pasos caminados', 'No se están contando en esta misión.', 'Contar mis pasos'),
    };
    final isCounting = questViewModel.stepStatus == StepCounterStatus.counting && isThisMission;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.secondary.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(
            Icons.directions_walk,
            color: isCounting ? AppColors.secondary : Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: isCounting ? textTheme.titleMedium : textTheme.titleSmall),
                if (subtitle != null) Text(subtitle, style: textTheme.bodySmall),
              ],
            ),
          ),
          if (actionLabel != null)
            TextButton(
              onPressed: questViewModel.retryStepTracking,
              child: Text(actionLabel),
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
  final QuestViewModel questViewModel;
  final List<(StepVerificationStrategy, VerificationResult)> verifications;

  const _StepTile({
    required this.step,
    required this.index,
    required this.isDone,
    required this.isCurrent,
    required this.questViewModel,
    required this.verifications,
  });

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
          if (isCurrent && verifications.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final (part, result) in verifications)
              part is PhotoVerification
                  ? _PhotoProofRow(questViewModel: questViewModel, result: result)
                  : _VerificationRow(part: part, result: result),
          ],
        ],
      ),
    );
  }
}

/// The location part of the current step's verification and its live
/// result: verified only from an actual GPS fix within 50 m; what's
/// persisted is just the step advancing (no per-step verification column).
class _VerificationRow extends StatelessWidget {
  final StepVerificationStrategy part;
  final VerificationResult result;

  const _VerificationRow({required this.part, required this.result});

  @override
  Widget build(BuildContext context) {
    final isLocation = part is LocationVerification;
    final label = isLocation ? 'Ubicación' : 'Foto de verificación';
    final outline = Theme.of(context).colorScheme.outline;
    final (IconData icon, Color iconColor, String detail) = switch (result) {
      Verified() => (Icons.check_circle, AppColors.secondary, 'Verificada automáticamente'),
      Pending(distanceMeters: final distance?) => (
        Icons.near_me_outlined,
        AppColors.primary,
        'Acércate al lugar · estás a ${_formatDistance(distance)}',
      ),
      Pending() => (Icons.my_location, AppColors.primary, 'Buscando tu ubicación…'),
      Unavailable(:final reason) => (
        isLocation ? Icons.location_off_outlined : Icons.camera_alt_outlined,
        outline,
        reason,
      ),
    };

    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, color: iconColor),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: Theme.of(context).textTheme.bodySmall),
                Text(
                  detail,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(color: outline),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 120 -> "120 m", 1530 -> "1.5 km".
String _formatDistance(double meters) =>
    meters < 1000 ? '${meters.round()} m' : '${(meters / 1000).toStringAsFixed(1)} km';

/// The photo part of the current step (feature f): take it, watch it
/// upload, or — without connection — retry it. Only an uploaded and
/// registered photo shows the check.
class _PhotoProofRow extends StatelessWidget {
  final QuestViewModel questViewModel;
  final VerificationResult result;

  const _PhotoProofRow({required this.questViewModel, required this.result});

  @override
  Widget build(BuildContext context) {
    final outline = Theme.of(context).colorScheme.outline;
    final pending = questViewModel.currentPendingPhotoProof;

    final (IconData icon, Color iconColor, String detail, Widget? action) =
        result is Verified
        ? (Icons.check_circle, AppColors.secondary, 'Foto subida y registrada', null)
        : questViewModel.isUploadingPhoto
        ? (
            Icons.cloud_upload_outlined,
            AppColors.primary,
            'Subiendo foto…',
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        : questViewModel.isCapturingPhoto
        ? (Icons.camera_alt_outlined, AppColors.primary, 'Abriendo la cámara…', null)
        : pending != null
        ? (
            Icons.cloud_off,
            AppColors.amber,
            pending.lastError ?? 'Tu foto está guardada en el teléfono, sin subir.',
            TextButton(
              onPressed: questViewModel.retryPhotoUpload,
              child: const Text('Reintentar subida'),
            ),
          )
        : (
            Icons.camera_alt_outlined,
            outline,
            questViewModel.photoErrorMessage ?? 'Toma una foto para completar este paso.',
            TextButton(
              onPressed: questViewModel.capturePhotoProof,
              child: const Text('Tomar foto'),
            ),
          );

    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: BorderRadius.circular(12),
      ),
      // The action sits under the text, not beside it: "Reintentar subida"
      // next to a long error message overflows on a 360 px phone.
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: iconColor),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Foto de verificación', style: Theme.of(context).textTheme.bodySmall),
                Text(
                  detail,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(color: outline),
                ),
                if (action != null) ...[const SizedBox(height: 6), action],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
