import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
import '../../core/category_labels.dart';
import '../../core/number_format.dart';
import '../../repository/quest_repository.dart';
import '../../viewmodel/auth/auth_view_model.dart';
import '../../viewmodel/profile/stats_view_model.dart';
import '../widgets/completion_likelihood_label.dart';

/// "Mis estadísticas", opened from Perfil: completed missions, the user's
/// completion rate per category and total walked steps.
class StatsView extends StatefulWidget {
  const StatsView({super.key});

  /// StatsViewModel is provided here, scoped to this route — not in
  /// app.dart — since only this screen uses it: it's created when the
  /// screen opens (fresh data every visit) and disposed when it closes.
  /// QuestRepository and AuthViewModel live above MaterialApp, so a pushed
  /// route can read them.
  static Route<void> route() => MaterialPageRoute(
    builder: (context) => ChangeNotifierProvider(
      create: (context) => StatsViewModel(
        context.read<QuestRepository>(),
        context.read<AuthViewModel>().userId!,
        summaryCache: context.read<StatsSummaryCache?>(),
      ),
      child: const StatsView(),
    ),
  );

  @override
  State<StatsView> createState() => _StatsViewState();
}

class _StatsViewState extends State<StatsView> {
  @override
  void initState() {
    super.initState();
    // Not in the provider's `create`: load() notifies right away, and
    // `create` runs during build (setState-during-build error).
    WidgetsBinding.instance.addPostFrameCallback((_) => context.read<StatsViewModel>().load());
  }

  @override
  Widget build(BuildContext context) {
    final statsViewModel = context.watch<StatsViewModel>();

    return Scaffold(
      appBar: AppBar(title: const Text('My stats')),
      body: SafeArea(
        child: switch (statsViewModel.status) {
          StatsStatus.loading => const Center(child: CircularProgressIndicator()),
          StatsStatus.error => _StatsMessage(
            icon: Icons.cloud_off,
            message: statsViewModel.errorMessage ?? 'Could not load your stats.',
            actionLabel: 'Retry',
            onAction: statsViewModel.load,
          ),
          StatsStatus.empty => _StatsMessage(
            icon: Icons.flag_outlined,
            message: "You haven't tried any quests yet. Accept one in Explore!",
            actionLabel: 'Back',
            onAction: () => Navigator.of(context).pop(),
          ),
          StatsStatus.data => RefreshIndicator(
            onRefresh: statsViewModel.load,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
              children: [
                if (statsViewModel.isFromCache) ...[
                  const _OfflineBanner(),
                  const SizedBox(height: 16),
                ],
                _SummaryRow(statsViewModel: statsViewModel),
                const SizedBox(height: 24),
                Text('By category', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(
                  'How many of the quests you accept you finish, based on your history',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                if (statsViewModel.categoryStats.isEmpty)
                  Text(
                    statsViewModel.isFromCache
                        ? 'Not available offline.'
                        : 'No category data yet.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  )
                else
                  ...statsViewModel.categoryStats.map((stat) => _CategoryRateRow(stat: stat)),
                const SizedBox(height: 24),
                _StepsCard(steps: statsViewModel.totalSteps),
                const SizedBox(height: 24),
                _WalksSection(statsViewModel: statsViewModel),
              ],
            ),
          ),
        },
      ),
    );
  }
}

class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? AppColors.primaryContainerDark : AppColors.primaryContainerLight,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          const Icon(Icons.cloud_off, color: AppColors.primary, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Offline: showing your data from your last visit.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  final StatsViewModel statsViewModel;

  const _SummaryRow({required this.statsViewModel});

  @override
  Widget build(BuildContext context) {
    final rate = statsViewModel.overallRate;
    return Row(
      children: [
        Expanded(
          child: _StatTile(
            icon: Icons.bolt,
            value: '${statsViewModel.completedCount}',
            label: 'Completed',
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _StatTile(
            icon: Icons.flag_outlined,
            value: '${statsViewModel.attemptCount}',
            label: 'Attempted',
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _StatTile(
            icon: Icons.insights,
            value: rate == null ? '—' : '${(rate * 100).round()} %',
            label: 'Overall rate',
          ),
        ),
      ],
    );
  }
}

/// Same look as Perfil's _StatCard so both screens read as one.
class _StatTile extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;

  const _StatTile({required this.icon, required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Icon(icon, color: AppColors.amber),
          const SizedBox(height: 6),
          Text(value, style: Theme.of(context).textTheme.titleLarge),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _CategoryRateRow extends StatelessWidget {
  final CategoryStat stat;

  const _CategoryRateRow({required this.stat});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(categoryLabelEs(stat.category), style: textTheme.titleSmall)),
              Text(
                '${stat.completed}/${stat.attempts} · ${(stat.rate * 100).round()} %',
                style: textTheme.bodySmall,
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: stat.rate,
              minHeight: 8,
              color: completionLevelColor(stat.level),
              backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
            ),
          ),
          const SizedBox(height: 4),
          CompletionLikelihoodLabel(level: stat.level),
        ],
      ),
    );
  }
}

/// Total walked steps from the podómetro. null = no attempt has step data
/// yet (no sensor, permission denied, or never walked with a mission
/// active) — shown as "—", not as 0.
class _StepsCard extends StatelessWidget {
  final int? steps;

  const _StepsCard({required this.steps});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          const Icon(Icons.directions_walk, color: AppColors.secondary, size: 32),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(steps == null ? '—' : formatThousands(steps!), style: textTheme.titleLarge),
                Text('Steps walked on quests', style: textTheme.bodySmall),
                if (steps == null)
                  Text(
                    'Counted by the pedometer while you do a quest.',
                    style: textTheme.bodySmall,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "Tus caminatas": every walk finished with the podómetro, kept in SQLite on
/// the device, so it reads the same offline.
class _WalksSection extends StatelessWidget {
  final StatsViewModel statsViewModel;

  const _WalksSection({required this.statsViewModel});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final longest = statsViewModel.longestWalk;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Your walks', style: textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          'Steps from quests you completed or abandoned, saved on your phone',
          style: textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        if (longest == null)
          Text(
            'No walks saved yet. They are recorded when you complete or abandon '
            'a quest with the pedometer on.',
            style: textTheme.bodyMedium,
          )
        else ...[
          Row(
            children: [
              Expanded(
                child: _StatTile(
                  icon: Icons.calendar_today,
                  value: formatThousands(statsViewModel.walkStepsLast7Days),
                  label: 'Last 7 days',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _StatTile(
                  icon: Icons.emoji_events_outlined,
                  value: formatThousands(longest.steps),
                  label: 'Longest walk',
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${statsViewModel.longestWalkTitle ?? 'Quest'} · ${_formatDate(longest.finishedAt)}',
            style: textTheme.bodySmall,
          ),
          if (statsViewModel.walkStepsByCategory.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('Steps by category', style: textTheme.titleSmall),
            const SizedBox(height: 8),
            for (final (:category, :steps) in statsViewModel.walkStepsByCategory)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Expanded(child: Text(categoryLabelEs(category), style: textTheme.bodyMedium)),
                    Text('${formatThousands(steps)} steps', style: textTheme.bodySmall),
                  ],
                ),
              ),
          ],
        ],
      ],
    );
  }

  /// 26/11/2026, in local time.
  static String _formatDate(DateTime date) {
    final local = date.toLocal();
    return '${local.day}/${local.month}/${local.year}';
  }
}

class _StatsMessage extends StatelessWidget {
  final IconData icon;
  final String message;
  final String actionLabel;
  final VoidCallback onAction;

  const _StatsMessage({
    required this.icon,
    required this.message,
    required this.actionLabel,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: onAction, child: Text(actionLabel)),
          ],
        ),
      ),
    );
  }
}
