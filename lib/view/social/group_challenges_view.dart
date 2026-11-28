import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../analytics/analytics_tracker.dart';
import '../../core/app_theme.dart';
import '../../core/category_labels.dart';
import '../../models/group_challenge.dart';
import '../../models/quest.dart';
import '../../repository/group_challenge_repository.dart';
import '../../repository/quest_repository.dart';
import '../../viewmodel/context/connectivity_view_model.dart';
import '../../viewmodel/quests/quest_view_model.dart';
import '../../viewmodel/social/group_challenges_view_model.dart';
import '../widgets/offline_notice.dart';

/// "Retos en grupo" (BQ2), opened from Explorar's "Descubre más": the user's
/// challenges with their progress and next step, the open ones to join, and
/// the group quests to start one from. Mirror of Kotlin's
/// GroupChallengesScreen, in Spanish.
class GroupChallengesView extends StatefulWidget {
  const GroupChallengesView({super.key});

  /// Provided here, scoped to this route like MissionHistoryView: created
  /// when the screen opens and disposed when it closes. The catalogue is
  /// Explore's (QuestViewModel), the one Kotlin reads too.
  static Route<void> route() => MaterialPageRoute(
    builder: (context) {
      final questViewModel = context.read<QuestViewModel>();
      return ChangeNotifierProvider(
        create: (context) => GroupChallengesViewModel(
          context.read<GroupChallengeRepository>(),
          context.read<QuestRepository>(),
          context.read<AnalyticsTracker>(),
          connectivity: context.read<ConnectivityViewModel>(),
          catalog: () => questViewModel.catalog,
        ),
        child: const GroupChallengesView(),
      );
    },
  );

  @override
  State<GroupChallengesView> createState() => _GroupChallengesViewState();
}

class _GroupChallengesViewState extends State<GroupChallengesView> {
  @override
  void initState() {
    super.initState();
    // Not in the provider's `create`: load() notifies right away.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => context.read<GroupChallengesViewModel>().load(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<GroupChallengesViewModel>();
    // The ViewModel reads Explore's catalogue when asked; this rebuilds the
    // screen when that catalogue arrives or changes.
    context.select<QuestViewModel?, List<Quest>?>((questViewModel) => questViewModel?.catalog);
    final textTheme = Theme.of(context).textTheme;
    final creatable = viewModel.creatableQuests;

    // Kotlin's GroupChallengesScreen: "← Back" and "↻ Refresh" text buttons,
    // then the bold headline and its tagline.
    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: viewModel.refresh,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton(onPressed: () => Navigator.of(context).maybePop(), child: const Text('← Back')),
                  Tooltip(
                    message: 'Refresh',
                    child: TextButton(
                      onPressed: viewModel.canRefresh ? viewModel.refresh : null,
                      child: const Text('↻ Refresh'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text('Group challenges', style: textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(
                'Small adventures, better together.',
                style: textTheme.bodyLarge?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              if (viewModel.hasMine) ...[
                Row(
                  children: [
                    Expanded(
                      child: _Metric(
                        icon: '👥',
                        value: viewModel.joinedCount,
                        label: viewModel.joinedCount == 1 ? 'Challenge joined' : 'Challenges joined',
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _Metric(
                        icon: '✓',
                        value: viewModel.completedSteps,
                        label: viewModel.completedSteps == 1 ? 'Step completed' : 'Steps completed',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
              const _Notice(
                icon: Icons.lock_outline,
                text:
                    'Shared for 7 days with signed-in users. Your steps are '
                    'self-reported and do not count toward your individual history. Only group '
                    'counts are shared.',
              ),
              ..._statusNotices(context, viewModel),
              if (viewModel.isFirstLoad)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 48),
                  child: Center(child: CircularProgressIndicator()),
                )
              else ...[
                const SizedBox(height: 20),
                _SectionTitle('My challenges', count: viewModel.hasMine ? viewModel.mine.length : null),
                const SizedBox(height: 10),
                if (!viewModel.hasMine)
                  const _EmptyCard(
                    icon: '☁️',
                    title: 'List unavailable',
                    description: 'Connect to see your challenges.',
                  )
                else if (viewModel.mine.isEmpty)
                  const _EmptyCard(
                    icon: '👥',
                    title: "You're not in any challenges yet",
                    description: 'Join an open one or create one below.',
                  ),
                for (final challenge in viewModel.mine)
                  _MyChallengeCard(challenge: challenge, viewModel: viewModel),
                const SizedBox(height: 20),
                _SectionTitle(
                  'Available challenges',
                  count: viewModel.hasAvailable ? viewModel.available.length : null,
                ),
                const SizedBox(height: 10),
                if (!viewModel.hasAvailable)
                  const _EmptyCard(
                    icon: '☁️',
                    title: 'List unavailable',
                    description: 'Connect to see open challenges.',
                  )
                else if (viewModel.available.isEmpty)
                  const _EmptyCard(
                    icon: '🌐',
                    title: 'No other open challenges',
                    description: 'You can create one below.',
                  ),
                for (final challenge in viewModel.available)
                  _AvailableChallengeCard(challenge: challenge, viewModel: viewModel),
                const SizedBox(height: 20),
                _SectionTitle('Create a challenge', count: creatable.length),
                const SizedBox(height: 10),
                if (creatable.isEmpty)
                  const _EmptyCard(
                    icon: '＋',
                    title: 'No new group quests to create from',
                    description: 'Your challenges are still in My challenges.',
                  ),
                for (final quest in creatable) _CreateChallengeCard(quest: quest, viewModel: viewModel),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Connection, progress, the last answer and the pending request, in that
  /// order, between the privacy note and the lists.
  List<Widget> _statusNotices(BuildContext context, GroupChallengesViewModel viewModel) {
    final pending = viewModel.pending;
    return [
      if (viewModel.isOffline) ...[
        const SizedBox(height: 12),
        OfflineNotice(
          message: viewModel.hasSavedLists
              ? OfflineMessages.groupChallenges
              : OfflineMessages.groupChallengesNothingSaved,
        ),
      ],
      if (viewModel.busy && !viewModel.isFirstLoad) ...[
        const SizedBox(height: 12),
        const LinearProgressIndicator(),
        const SizedBox(height: 6),
        Text(
          viewModel.isSubmitting ? 'Sending request…' : 'Updating challenges…',
          style: Theme.of(context).textTheme.labelMedium,
        ),
      ],
      if (viewModel.someListsFailed && !viewModel.isOffline && !viewModel.busy) ...[
        const SizedBox(height: 12),
        _Notice(
          icon: Icons.cloud_off,
          text: 'Some lists could not be updated. Showing the last saved ones.',
          actionLabel: 'Retry',
          onAction: viewModel.canRefresh ? viewModel.refresh : null,
        ),
      ],
      if (viewModel.message != null) ...[
        const SizedBox(height: 12),
        _Notice(icon: Icons.info_outline, text: viewModel.message!),
      ],
      if (pending != null) ...[
        const SizedBox(height: 12),
        _PendingCard(action: pending, viewModel: viewModel),
      ],
    ];
  }
}

class _MyChallengeCard extends StatelessWidget {
  final GroupChallenge challenge;
  final GroupChallengesViewModel viewModel;

  const _MyChallengeCard({required this.challenge, required this.viewModel});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final quest = viewModel.questFor(challenge.questId);
    final nextStep = viewModel.nextStepFor(challenge);
    final percent = (challenge.progressFraction * 100).floor();

    return _ChallengeCard(
      children: [
        _ChallengeHeading(title: challenge.title, quest: quest),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            _Pill('👥 ${_participantLabel(challenge.participants)}'),
            _Pill('✓ ${_finishedLabel(challenge.completedParticipants)}'),
          ],
        ),
        const Divider(height: 1),
        Row(
          children: [
            Expanded(child: Text('Your progress', style: textTheme.titleSmall)),
            Text(
              '$percent%',
              style: textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w700),
            ),
          ],
        ),
        LinearProgressIndicator(
          value: challenge.progressFraction,
          minHeight: 6,
          borderRadius: BorderRadius.circular(3),
        ),
        Text(
          '${challenge.progress} of ${challenge.totalSteps} steps completed',
          style: textTheme.bodySmall,
        ),
        if (nextStep != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _primaryContainer(context),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'NEXT STEP · ${challenge.progress + 1}',
                  style: textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 4),
                Text(nextStep.title, style: textTheme.titleSmall),
                if (nextStep.description.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(nextStep.description, style: textTheme.bodySmall),
                ],
              ],
            ),
          ),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: viewModel.canWrite && !challenge.isCompleted
                ? () => viewModel.markNextStep(challenge)
                : null,
            child: Text(challenge.isCompleted ? 'Completed' : 'Mark next step'),
          ),
        ),
      ],
    );
  }
}

class _AvailableChallengeCard extends StatelessWidget {
  final GroupChallenge challenge;
  final GroupChallengesViewModel viewModel;

  const _AvailableChallengeCard({required this.challenge, required this.viewModel});

  @override
  Widget build(BuildContext context) {
    return _ChallengeCard(
      children: [
        _ChallengeHeading(title: challenge.title, quest: viewModel.questFor(challenge.questId)),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            _Pill('👥 ${_participantLabel(challenge.participants)}'),
            _Pill(challenge.totalSteps == 1 ? '1 step' : '${challenge.totalSteps} steps'),
          ],
        ),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: viewModel.canWrite ? () => viewModel.joinChallenge(challenge) : null,
            child: const Text('Join'),
          ),
        ),
      ],
    );
  }
}

class _CreateChallengeCard extends StatelessWidget {
  final Quest quest;
  final GroupChallengesViewModel viewModel;

  const _CreateChallengeCard({required this.quest, required this.viewModel});

  @override
  Widget build(BuildContext context) {
    return _ChallengeCard(
      children: [
        _ChallengeHeading(title: quest.title, quest: quest),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: viewModel.canWrite ? () => viewModel.createChallenge(quest) : null,
            child: const Text('Create challenge'),
          ),
        ),
      ],
    );
  }
}

/// The request whose result is unknown, with the only way to resend it.
class _PendingCard extends StatelessWidget {
  final GroupAction action;
  final GroupChallengesViewModel viewModel;

  const _PendingCard({required this.action, required this.viewModel});

  @override
  Widget build(BuildContext context) {
    final what = switch (action.operation) {
      GroupAction.create => 'Create challenge',
      GroupAction.join => 'Join challenge',
      GroupAction.progress => 'Mark step ${action.progressValue ?? ''}',
      _ => action.operation,
    };
    final title = action.title;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.amber.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.help_outline, size: 18, color: AppColors.amber),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  const GroupActionUnconfirmedException().message,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 26),
            child: Text(
              title == null ? what : '$what · $title',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: viewModel.canRetryPending ? viewModel.retryPending : null,
              icon: const Icon(Icons.replay, size: 18),
              label: const Text('Retry pending request'),
            ),
          ),
        ],
      ),
    );
  }
}

String _participantLabel(int count) => count == 1 ? '1 participant' : '$count participants';

String _finishedLabel(int count) => count == 1 ? '1 finished' : '$count finished';

Color _primaryContainer(BuildContext context) => Theme.of(context).brightness == Brightness.dark
    ? AppColors.primaryContainerDark
    : AppColors.primaryContainerLight;

class _ChallengeCard extends StatelessWidget {
  final List<Widget> children;

  const _ChallengeCard({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(height: 12),
            children[i],
          ],
        ],
      ),
    );
  }
}

class _ChallengeHeading extends StatelessWidget {
  final String title;
  final Quest? quest;

  const _ChallengeHeading({required this.title, required this.quest});

  @override
  Widget build(BuildContext context) {
    final quest = this.quest;
    return Row(
      children: [
        Container(
          width: 48,
          height: 48,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _primaryContainer(context),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(quest?.emoji ?? '👥', style: const TextStyle(fontSize: 24)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              if (quest != null) ...[
                const SizedBox(height: 2),
                Text(
                  '${categoryLabelEs(quest.category)} · ${quest.durationMinutes} min',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _Metric extends StatelessWidget {
  final String icon;
  final int value;
  final String label;

  const _Metric({required this.icon, required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _primaryContainer(context),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(icon, style: textTheme.titleLarge?.copyWith(color: Theme.of(context).colorScheme.primary)),
          const SizedBox(height: 4),
          Text('$value', style: textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
          Text(label, style: textTheme.labelMedium),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String label;

  const _Pill(this.label);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(label, style: Theme.of(context).textTheme.labelSmall),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;

  /// null when the list isn't known yet.
  final int? count;

  const _SectionTitle(this.title, {required this.count});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(title, style: Theme.of(context).textTheme.titleLarge)),
        if (count != null) _Pill('$count'),
      ],
    );
  }
}

class _EmptyCard extends StatelessWidget {
  final String icon;
  final String title;
  final String description;

  const _EmptyCard({required this.icon, required this.title, required this.description});

  @override
  Widget build(BuildContext context) {
    return _ChallengeCard(
      children: [
        Row(
          children: [
            Text(icon, style: const TextStyle(fontSize: 24)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Text(description, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _Notice extends StatelessWidget {
  final IconData icon;
  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _Notice({required this.icon, required this.text, this.actionLabel, this.onAction});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: Theme.of(context).colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: Theme.of(context).textTheme.bodySmall)),
          if (actionLabel != null)
            TextButton(onPressed: onAction, child: Text(actionLabel!)),
        ],
      ),
    );
  }
}
