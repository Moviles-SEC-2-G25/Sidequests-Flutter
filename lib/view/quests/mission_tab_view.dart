import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
import '../../core/number_format.dart';
import '../../core/verification/step_verification_strategy.dart';
import '../../core/verification/verification_strategies.dart';
import '../../data/services/step_counter_service.dart';
import '../../models/quest_step.dart';
import '../../models/user_quest.dart';
import '../../viewmodel/quests/quest_view_model.dart';
import '../widgets/offline_notice.dart';
import '../widgets/sponsored_badge.dart';
import '../widgets/sq_components.dart';
import 'abandon_mission_view.dart';
import 'quest_completed_view.dart';

/// The "Misión" tab: the current accepted or in-progress quest's step
/// checklist. Also reachable as a pushed full
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
  QuestViewModel? _questViewModel;

  /// Pushed (not the tab, which HomeShell reports): on screen while nothing
  /// covers this route. BQ11 only measures while a Misión screen is showing.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.isTab) return;
    _questViewModel = context.read<QuestViewModel>();
    _questViewModel!.setMissionScreenVisible(this, ModalRoute.isCurrentOf(context) ?? true);
  }

  @override
  void dispose() {
    _questViewModel?.setMissionScreenVisible(this, false);
    super.dispose();
  }

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
      body: SafeArea(
        child: mission == null || quest == null
            ? _NoMissionState(isTab: widget.isTab)
            : _MissionChecklist(
                mission: mission,
                quest: quest,
                questViewModel: questViewModel,
                isTab: widget.isTab,
              ),
      ),
    );
  }
}

/// Kotlin's QuestHomeScreen: "No active quest" and a way to Explore.
class _NoMissionState extends StatelessWidget {
  final bool isTab;

  const _NoMissionState({required this.isTab});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!isTab)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
            child: SqCircleButton(glyph: '←', fontSize: 22, onTap: () => Navigator.of(context).pop()),
          ),
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('No active quest', style: textTheme.headlineSmall),
                  const SizedBox(height: 12),
                  Text(
                    'Pick a quest in Explore to get started.',
                    textAlign: TextAlign.center,
                    style: textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: () {
                      // Back to HomeShell, whichever way this screen was reached.
                      context.read<QuestViewModel>().requestExploreTab();
                      Navigator.of(context).popUntil((route) => route.isFirst);
                    },
                    child: const Text('Explore quests'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Kotlin's ActiveQuestScreen: round back button, "ACTIVE QUEST" + title and
/// "Exit", a teal progress bar, the walking card and one card per step; the
/// current step's card holds its verification and the complete button.
class _MissionChecklist extends StatelessWidget {
  final UserQuest mission;
  final dynamic quest;
  final QuestViewModel questViewModel;
  final bool isTab;

  const _MissionChecklist({
    required this.mission,
    required this.quest,
    required this.questViewModel,
    required this.isTab,
  });

  void _back(BuildContext context) {
    if (isTab) {
      context.read<QuestViewModel>().requestExploreTab();
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (questViewModel.isLoadingSteps && questViewModel.steps.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    final steps = questViewModel.steps;
    final completed = mission.completedSteps.toSet();
    final currentIndex = mission.currentStep;
    // Progress is saved on the server: offline the mission can be reviewed,
    // and the location check-in and photo still wait on the device, but
    // "Complete" is blocked instead of failing after the tap.
    final isOffline = watchIsOffline(context);
    final onSurface = Theme.of(context).colorScheme.onSurface;

    // A step marked done by mistake can be taken back: the last completed one
    // offers it. Like "Complete", it's saved on the server (off without network).
    final lastCompleted = mission.completedSteps.isEmpty ? null : mission.completedSteps.last;
    Widget goBackButton() => Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: isOffline || questViewModel.isCompletingStep
            ? null
            : () async {
                final messenger = ScaffoldMessenger.of(context);
                final wentBack = await questViewModel.goBackAStep(mission);
                final error = questViewModel.stepErrorMessage;
                if (!wentBack && error != null) {
                  messenger.showSnackBar(SnackBar(content: Text(error)));
                }
              },
        icon: const Icon(Icons.undo, size: 18),
        label: const Text('Back to this step'),
      ),
    );

    Widget completeButton() {
      if (isOffline) {
        return FilledButton.icon(
          onPressed: null,
          icon: const Icon(Icons.wifi_off, size: 18),
          label: const Text('Connect to complete'),
        );
      }
      return FilledButton(
        style: sqPrimaryButtonStyle(AppColors.secondary),
        // The step's strategy decides: a photo step stays blocked until
        // its proof is uploaded; location never blocks.
        onPressed: currentIndex < steps.length && questViewModel.canCompleteCurrentStep(steps[currentIndex], quest)
            ? () async {
                final navigator = Navigator.of(context);
                final messenger = ScaffoldMessenger.of(context);
                final completedMission = await questViewModel.completeCurrentStep(mission);
                final error = questViewModel.stepErrorMessage;
                if (error != null) {
                  // Not saved (the connection dropped): the step stays where it was.
                  messenger.showSnackBar(SnackBar(content: Text(error)));
                  return;
                }
                if (!completedMission || !navigator.mounted) return;
                navigator.push(
                  MaterialPageRoute(
                    builder: (_) => QuestCompletedView(mission: mission, quest: quest),
                  ),
                );
              }
            : null,
        child: Text(currentIndex >= steps.length - 1 ? 'Complete quest →' : 'Complete this step →'),
      );
    }

    final children = <Widget>[
      Row(
        children: [
          SqCircleButton(glyph: '←', fontSize: 22, onTap: () => _back(context)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SqSectionLabel('ACTIVE QUEST', color: AppColors.secondary),
                Text(quest.title, style: Theme.of(context).textTheme.titleLarge),
                if (quest.isSponsored) ...[const SizedBox(height: 4), const SponsoredBadge()],
              ],
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => AbandonMissionView(mission: mission, totalSteps: steps.length),
              ),
            ),
            style: TextButton.styleFrom(
              foregroundColor: onSurface.withValues(alpha: .6),
              minimumSize: const Size(56, 48),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('Exit', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
      if (steps.isNotEmpty) SqProgressBar(value: completed.length / steps.length),
      // A check-in saved for the current step says what happens with it
      // ("it will be saved when you are back online"): saying instead that
      // the step needs the internet would contradict it.
      if (isOffline && !questViewModel.isCheckInSavedForCurrentStep)
        const OfflineNotice(message: OfflineMessages.missionProgress),
      if (steps.isNotEmpty) ...[
        _WalkedStepsCard(mission: mission, questViewModel: questViewModel),
        if (questViewModel.canShareBq11(mission, quest)) _ZoneTimeSharingCard(questViewModel: questViewModel),
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
            action: i == currentIndex && !completed.contains(i)
                ? completeButton()
                : i == lastCompleted && questViewModel.canGoBackAStep(mission)
                ? goBackButton()
                : null,
          ),
        // A finished checklist whose last step isn't marked yet keeps a button.
        if (currentIndex >= steps.length) completeButton(),
      ] else
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Text('This quest has no steps defined.'),
        ),
    ];

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (index, child) in children.indexed) ...[if (index > 0) const SizedBox(height: 14), child],
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
    final textTheme = Theme.of(context).textTheme;
    final isThisMission = questViewModel.stepTrackedUserQuestId == mission.id;

    // title null = counting: the live number, from missionStepsListenable.
    final (String? title, String? subtitle, String? actionLabel) = switch (questViewModel.stepStatus) {
      StepCounterStatus.counting when isThisMission => (null, null, null),
      StepCounterStatus.permissionDenied => (
        'Steps walked',
        'Turn on "Physical activity" to count them during the quest.',
        'Allow',
      ),
      StepCounterStatus.permissionPermanentlyDenied => (
        'Steps walked',
        'Turn on "Physical activity" in your phone settings to count them.',
        'Open settings',
      ),
      StepCounterStatus.unavailable => (
        'Steps walked',
        'Your phone has no step counter.',
        null,
      ),
      _ => ('Steps walked', 'Not being counted on this quest.', 'Count my steps'),
    };
    final isCounting = questViewModel.stepStatus == StepCounterStatus.counting && isThisMission;

    // Kotlin's QuestWalkingCard: a plain card, 16 dp padding.
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(
              Icons.directions_walk,
              color: isCounting ? AppColors.secondary : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (title != null)
                    Text(title, style: textTheme.titleMedium)
                  else
                    // Only this text rebuilds with each step; the ViewModel
                    // doesn't notify for them (micro-optimization).
                    ValueListenableBuilder<int?>(
                      valueListenable: questViewModel.missionStepsListenable,
                      builder: (context, steps, _) => Text(
                        steps == null
                            ? 'Waiting for your first steps…'
                            : '${formatThousands(steps)} steps walked',
                        style: steps == null ? textTheme.titleMedium : textTheme.headlineSmall,
                      ),
                    ),
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
      ),
    );
  }
}

/// BQ11 opt-in, off by default and per attempt.
class _ZoneTimeSharingCard extends StatelessWidget {
  final QuestViewModel questViewModel;

  const _ZoneTimeSharingCard({required this.questViewModel});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final error = questViewModel.bq11SharingError;
    // Material, not a decorated Container: the switch's ripple paints on it.
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              key: const Key('bq11SharingSwitch'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Share time in the area (anonymous)'),
              subtitle: const Text(
                'Optional. Weekends in Bogotá only, with this screen open: '
                'when you complete, we send how long you spent on a commercial block '
                'in the pilot (if it was more than 20 min), never your coordinates. '
                'Turn it off before completing and nothing is sent.',
              ),
              value: questViewModel.isSharingBq11,
              onChanged: questViewModel.setBq11Sharing,
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(
                  error,
                  style: textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
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

  /// The current step's complete button, inside its card as in Kotlin.
  final Widget? action;

  const _StepTile({
    required this.step,
    required this.index,
    required this.isDone,
    required this.isCurrent,
    required this.questViewModel,
    required this.verifications,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Kotlin's step card: teal when done, indigo when current, bordered surface otherwise.
    final background = isDone
        ? AppColors.secondary.withValues(alpha: .10)
        : isCurrent
        ? AppColors.primary.withValues(alpha: .11)
        : Colors.transparent;
    final border = isDone
        ? AppColors.secondary.withValues(alpha: .5)
        : isCurrent
        ? AppColors.primary.withValues(alpha: .42)
        : scheme.outline;
    final badge = isDone
        ? AppColors.secondary
        : isCurrent
        ? AppColors.primary
        : scheme.primaryContainer;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Color.alphaBlend(background, scheme.surface),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(shape: BoxShape.circle, color: badge),
                child: Text(
                  isDone ? '✓' : '${index + 1}',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: isDone || isCurrent ? Colors.white : scheme.onSurface,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(step.title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                    if (step.description.isNotEmpty)
                      Text(
                        step.description,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurface.withValues(alpha: .64),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (isCurrent && verifications.isNotEmpty) ...[
            const SizedBox(height: 4),
            for (final (part, result) in verifications)
              part is PhotoVerification
                  ? _PhotoProofRow(questViewModel: questViewModel, result: result)
                  : _VerificationRow(
                      part: part,
                      result: result,
                      isSavedForLater:
                          part is LocationVerification && questViewModel.isCheckInSavedForCurrentStep,
                    ),
          ],
          if (action != null) ...[const SizedBox(height: 12), action!],
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

  /// Verified earlier and waiting for a connection: true even after walking
  /// away, when [result] no longer says so.
  final bool isSavedForLater;

  const _VerificationRow({required this.part, required this.result, this.isSavedForLater = false});

  @override
  Widget build(BuildContext context) {
    final isLocation = part is LocationVerification;
    final label = isLocation ? 'Location' : 'Verification photo';
    final outline = Theme.of(context).colorScheme.onSurfaceVariant;
    final (IconData icon, Color iconColor, String detail) = switch (result) {
      _ when isSavedForLater => (
        Icons.check_circle,
        AppColors.secondary,
        '📍 You made it. It will be saved when you are back online.',
      ),
      Verified() => (Icons.check_circle, AppColors.secondary, 'Verified automatically'),
      Pending(distanceMeters: final distance?) => (
        Icons.near_me_outlined,
        AppColors.primary,
        'Get closer to the place · you are ${_formatDistance(distance)} away',
      ),
      Pending() => (Icons.my_location, Theme.of(context).colorScheme.primary, 'Finding your location…'),
      Unavailable(:final reason) => (
        isLocation ? Icons.location_off_outlined : Icons.camera_alt_outlined,
        outline,
        reason,
      ),
    };

    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: result is Verified
            ? AppColors.secondary.withValues(alpha: .16)
            : Theme.of(context).colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(16),
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
    final outline = Theme.of(context).colorScheme.onSurfaceVariant;
    final pending = questViewModel.currentPendingPhotoProof;
    // The camera and the copy on the device work offline; only the upload
    // waits, and it starts by itself when the connection is back.
    final isOffline = watchIsOffline(context);

    final (IconData icon, Color iconColor, String detail, Widget? action) =
        result is Verified
        ? (Icons.check_circle, AppColors.secondary, 'Photo uploaded and recorded', null)
        : questViewModel.isUploadingPhoto
        ? (
            Icons.cloud_upload_outlined,
            AppColors.primary,
            'Uploading photo…',
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        : questViewModel.isCapturingPhoto
        ? (Icons.camera_alt_outlined, AppColors.primary, 'Opening the camera…', null)
        : pending != null && isOffline
        ? (Icons.cloud_off, AppColors.amber, OfflineMessages.photoUpload, null)
        : pending != null
        ? (
            Icons.cloud_off,
            AppColors.amber,
            pending.lastError ?? 'Your photo is saved on the phone, not uploaded yet.',
            TextButton(
              onPressed: questViewModel.retryPhotoUpload,
              child: const Text('Retry upload'),
            ),
          )
        : (
            Icons.camera_alt_outlined,
            outline,
            questViewModel.photoErrorMessage ??
                (isOffline
                    ? 'Offline: you can take the photo; it will be saved on the phone and uploaded when you reconnect.'
                    : 'Take a photo to complete this step.'),
            TextButton(
              onPressed: questViewModel.capturePhotoProof,
              child: const Text('Take photo'),
            ),
          );

    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: result is Verified
            ? AppColors.secondary.withValues(alpha: .16)
            : Theme.of(context).colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(16),
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
                Text('Verification photo', style: Theme.of(context).textTheme.bodySmall),
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
