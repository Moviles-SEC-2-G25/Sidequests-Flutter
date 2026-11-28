import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
import '../../models/abandonment_reason.dart';
import '../../models/user_quest.dart';
import '../../viewmodel/profile/profile_view_model.dart';
import '../../viewmodel/quests/quest_view_model.dart';
import '../widgets/sq_components.dart';
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

  /// "Save and come back later": nothing to write (progress is already saved
  /// step by step), so it just leaves the mission for Explore. Unlike "Keep
  /// going", which returns to the mission itself.
  void _saveAndExit() {
    final questViewModel = context.read<QuestViewModel>();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Progress saved. Continue anytime from the Quest tab.')),
    );
    questViewModel.requestExploreTab();
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  /// Abandons the attempt (offline it's queued, see [QuestViewModel.abandonQuest]).
  /// With [findAnother] it then offers the alternatives; without it, it just
  /// ends the quest and goes back to Explore.
  Future<void> _abandon({required bool findAnother}) async {
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
        SnackBar(content: Text(questViewModel.errorMessage ?? 'Could not save.')),
      );
      return;
    }
    if (questViewModel.abandonmentQueued) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Quest abandoned offline: it will sync when you reconnect.')),
      );
    }
    final navigator = Navigator.of(context);
    if (!findAnother || questViewModel.questAlternatives == null) {
      // Just ending it (or it was already abandoned): no suggestions. The
      // pending alternatives load is dropped before it shows or logs anything.
      questViewModel.dismissQuestAlternatives();
      if (!findAnother && !questViewModel.abandonmentQueued) {
        messenger.showSnackBar(const SnackBar(content: Text('Quest ended.')));
      }
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
    final textTheme = Theme.of(context).textTheme;
    final onSurface = Theme.of(context).colorScheme.onSurface;

    // Kotlin's ExitFlowScreen: "PAUSING …", the headline, the progress bar,
    // the reason chips, then save / keep going / start another.
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 16),
              SqSectionLabel('PAUSING ${(quest?.title ?? 'this quest').toUpperCase()}', color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 6),
              Text('Life happens. What do you want to do?', style: textTheme.headlineMedium),
              const SizedBox(height: 10),
              SqProgressBar(value: progress),
              if (widget.totalSteps > 0) ...[
                const SizedBox(height: 6),
                Text(
                  '$completed of ${widget.totalSteps} steps completed · paused at step ${widget.mission.currentStep + 1}',
                  style: textTheme.bodySmall?.copyWith(color: onSurface.withValues(alpha: .6)),
                ),
              ],
              const SizedBox(height: 22),
              // Keep the quest: back to it, or out to Explore with it paused.
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: sqPrimaryButtonStyle(AppColors.secondary),
                  onPressed: _isSaving ? null : () => Navigator.of(context).pop(),
                  child: const Text('Keep going'),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _isSaving ? null : _saveAndExit,
                  child: const Text('Save and come back later'),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Your progress stays saved; the quest waits for you in the Quest tab.',
                  style: textTheme.bodySmall?.copyWith(color: onSurface.withValues(alpha: .6)),
                ),
              ),
              const SizedBox(height: 28),
              // End the quest: an optional reason, then end it or end it and
              // look for another one.
              Text("If you're ending it, what got in the way?", style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              Text(
                'Optional, it helps us improve.',
                style: textTheme.bodySmall?.copyWith(color: onSurface.withValues(alpha: .6)),
              ),
              const SizedBox(height: 8),
              for (final reason in AbandonmentReason.values) ...[
                _ReasonChip(
                  reason: reason,
                  selected: _selectedReason == reason,
                  onTap: () => setState(() => _selectedReason = _selectedReason == reason ? null : reason),
                ),
                const SizedBox(height: 8),
              ],
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                    side: BorderSide(color: Theme.of(context).colorScheme.error),
                  ),
                  onPressed: _isSaving ? null : () => _abandon(findAnother: false),
                  child: const Text('End quest'),
                ),
              ),
              const SizedBox(height: 4),
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: _isSaving ? null : () => _abandon(findAnother: true),
                  style: TextButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  child: _isSaving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Start another quest', style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Kotlin's ChoiceChip with an emoji: a pill that fills indigo when picked.
class _ReasonChip extends StatelessWidget {
  final AbandonmentReason reason;
  final bool selected;
  final VoidCallback onTap;

  const _ReasonChip({required this.reason, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textStyle = Theme.of(context).textTheme.labelLarge?.copyWith(
      color: selected ? Colors.white : scheme.onSurface,
    );
    return Material(
      color: selected ? AppColors.primary : scheme.primaryContainer,
      shape: StadiumBorder(side: selected ? BorderSide.none : BorderSide(color: scheme.outline)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(reason.emoji),
              const SizedBox(width: 6),
              Flexible(child: Text(reason.label, style: textStyle)),
            ],
          ),
        ),
      ),
    );
  }
}
