import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
import '../../core/category_labels.dart';
import '../../data/offline/offline_pack_entry.dart';
import '../../models/quest.dart';
import '../../viewmodel/offline/offline_pack_view_model.dart';
import '../../viewmodel/quests/quest_view_model.dart';
import '../quests/quest_detail_view.dart';
import '../widgets/offline_notice.dart';
import '../widgets/sq_components.dart';

/// "Paquete offline": the quests picked to keep, with their steps, for when
/// the connection drops (Kotlin's OfflinePackScreen). Opened from Perfil.
class OfflinePackView extends StatelessWidget {
  const OfflinePackView({super.key});

  static Route<void> route() => MaterialPageRoute(builder: (_) => const OfflinePackView());

  static String summary(int quests, int ready) =>
      '$quests ${quests == 1 ? 'quest' : 'quests'} · $ready ready';

  static String statusLabel(OfflinePackStatus status) => switch (status) {
    OfflinePackStatus.ready => 'Ready to use offline',
    OfflinePackStatus.pendingDownload => 'Waiting for connection',
    OfflinePackStatus.downloading => 'Preparing content…',
    OfflinePackStatus.failed => 'Download failed',
  };

  @override
  Widget build(BuildContext context) {
    final pack = context.watch<OfflinePackViewModel>();
    final questViewModel = context.watch<QuestViewModel>();
    final isOffline = watchIsOffline(context);
    final textTheme = Theme.of(context).textTheme;
    final entries = pack.entries;
    final waiting = entries.any((e) => e.status != OfflinePackStatus.ready);

    final scheme = Theme.of(context).colorScheme;
    final sectionStyle = textTheme.labelMedium?.copyWith(color: scheme.primary);

    // Kotlin's OfflinePackScreen: bold headline + summary with "Done", then
    // YOUR OFFLINE PACK and the quests to add.
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Offline Pack',
                          style: textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        Text(
                          summary(entries.length, pack.readyCount),
                          style: textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  TextButton(onPressed: () => Navigator.of(context).maybePop(), child: const Text('Done')),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(18, 4, 18, 12),
                children: [
                  Text(
                    'Their details and steps stay saved on the phone for when you lose connection.',
                    style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  if (isOffline && waiting) ...[
                    const SizedBox(height: 12),
                    const OfflineNotice(message: OfflineMessages.offlinePackPending),
                  ],
                  if (pack.errorMessage != null) ...[
                    const SizedBox(height: 12),
                    Text(pack.errorMessage!, style: textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error)),
                  ],
                  // Kotlin keeps the retry right under the notices, above the pack.
                  if (pack.hasPendingWork) ...[
                    const SizedBox(height: 10),
                    if (isOffline) ...[
                      const OfflineNotice(message: OfflineMessages.offlinePackRetry),
                      const SizedBox(height: 8),
                    ],
                    OutlinedButton.icon(
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry'),
                      onPressed: isOffline ? null : () => pack.retry(isOnline: true),
                    ),
                  ],
                  const SizedBox(height: 10),
                  Text('YOUR OFFLINE PACK', style: sectionStyle),
                  const SizedBox(height: 10),
                  if (entries.isEmpty)
                    Text(
                      'No quests in your pack yet. Add the ones you want available offline.',
                      style: textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                    )
                  else
                    for (final entry in entries)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _PackEntryCard(
                          entry: entry,
                          quest: questViewModel.questById(entry.questId),
                          onRemove: () => pack.remove(entry.questId),
                        ),
                      ),
                  const SizedBox(height: 10),
                  Text('AVAILABLE QUESTS', style: sectionStyle),
                  const SizedBox(height: 10),
                  FilledButton.icon(
                    icon: const Icon(Icons.add),
                    label: const Text('Add quests'),
                    onPressed: () => Navigator.of(
                      context,
                    ).push(MaterialPageRoute<void>(builder: (_) => const _AddQuestsView())),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PackEntryCard extends StatelessWidget {
  final OfflinePackEntry entry;
  final Quest? quest;
  final VoidCallback onRemove;

  const _PackEntryCard({required this.entry, required this.quest, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final quest = this.quest;
    final (IconData icon, Color color) = switch (entry.status) {
      OfflinePackStatus.ready => (Icons.offline_pin, AppColors.secondary),
      OfflinePackStatus.pendingDownload => (Icons.schedule, Theme.of(context).colorScheme.onSurfaceVariant),
      OfflinePackStatus.downloading => (Icons.downloading, Theme.of(context).colorScheme.primary),
      OfflinePackStatus.failed => (Icons.error_outline, Theme.of(context).colorScheme.error),
    };

    // Kotlin's selected-quest card: surfaceVariant, 12 dp padding.
    return Material(
      color: Theme.of(context).colorScheme.primaryContainer,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        // Its detail and steps, from the cache when there's no connection.
        onTap: quest == null
            ? null
            : () => Navigator.of(
                context,
              ).push(MaterialPageRoute<void>(builder: (_) => QuestDetailView(quest: quest))),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 4, 12),
          child: Row(
            children: [
              Text(quest?.emoji ?? '🗺️', style: const TextStyle(fontSize: 26)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      quest?.title ?? 'Saved quest',
                      style: textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Icon(icon, size: 16, color: color),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            OfflinePackView.statusLabel(entry.status),
                            style: textTheme.bodySmall?.copyWith(color: color),
                          ),
                        ),
                      ],
                    ),
                    if (entry.message != null)
                      Text(
                        entry.message!,
                        style: textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error),
                      ),
                  ],
                ),
              ),
              Tooltip(
                message: 'Remove from pack',
                child: TextButton(onPressed: onRemove, child: const Text('Remove')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The catalogue's quests not in the pack yet.
class _AddQuestsView extends StatelessWidget {
  const _AddQuestsView();

  @override
  Widget build(BuildContext context) {
    final pack = context.watch<OfflinePackViewModel>();
    final questViewModel = context.watch<QuestViewModel>();
    final isOffline = watchIsOffline(context);
    final available = [
      for (final quest in questViewModel.catalog)
        if (!pack.contains(quest.id)) quest,
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Add quests')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          children: [
            if (isOffline) ...[
              const OfflineNotice(message: OfflineMessages.offlinePackPending),
              const SizedBox(height: 12),
            ],
            if (available.isEmpty)
              Text(
                'All catalog quests are already in your pack.',
                style: Theme.of(context).textTheme.bodyMedium,
              )
            else
              for (final quest in available)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  // Kotlin's available-quest card: plain card, "Add" pill.
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                    children: [
                      Text(quest.emoji ?? '🗺️', style: const TextStyle(fontSize: 26)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              quest.title,
                              style: Theme.of(context).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
                            ),
                            Text(
                              '${quest.durationMinutes} min · ${categoryLabelEs(quest.category)}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        // Only as wide as its text, next to the quest.
                        style: sqPillButtonStyle(),
                        onPressed: () => pack.add(quest.id, isOnline: !readIsOffline(context)),
                        child: const Text('Add'),
                      ),
                    ],
                  ),
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}
