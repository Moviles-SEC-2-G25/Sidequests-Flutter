import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
import '../../core/category_labels.dart';
import '../../core/mission_history.dart';
import '../../core/number_format.dart';
import '../../models/abandonment_reason.dart';
import '../../repository/quest_repository.dart';
import '../../viewmodel/auth/auth_view_model.dart';
import '../../viewmodel/profile/attempt_evidence_view_model.dart';
import '../../viewmodel/profile/mission_history_view_model.dart';
import '../quests/quest_detail_view.dart';
import 'attempt_evidence_view.dart';

/// "Mi bitácora", opened from Perfil: every mission the user tried —
/// completed (with the rating given), abandoned (with why) and in progress —
/// grouped by month, with a search and a filter. Works offline from the
/// device's saved copy.
class MissionHistoryView extends StatefulWidget {
  const MissionHistoryView({super.key});

  /// Provided here, scoped to this route, like StatsView: created when the
  /// screen opens (fresh data every visit) and disposed when it closes.
  static Route<void> route() => MaterialPageRoute(
    builder: (context) => ChangeNotifierProvider(
      create: (context) => MissionHistoryViewModel(
        context.read<QuestRepository>(),
        context.read<AuthViewModel>().userId!,
      ),
      child: const MissionHistoryView(),
    ),
  );

  @override
  State<MissionHistoryView> createState() => _MissionHistoryViewState();
}

class _MissionHistoryViewState extends State<MissionHistoryView> {
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Not in the provider's `create`: load() notifies right away, and
    // `create` runs during build (setState-during-build error).
    WidgetsBinding.instance.addPostFrameCallback((_) => context.read<MissionHistoryViewModel>().load());
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final historyViewModel = context.watch<MissionHistoryViewModel>();

    return Scaffold(
      appBar: AppBar(title: const Text('Mi bitácora')),
      body: SafeArea(
        child: switch (historyViewModel.status) {
          HistoryStatus.loading => const Center(child: CircularProgressIndicator()),
          HistoryStatus.error => _HistoryMessage(
            icon: Icons.cloud_off,
            message: historyViewModel.errorMessage ?? 'No se pudo cargar tu bitácora.',
            actionLabel: 'Reintentar',
            onAction: historyViewModel.load,
          ),
          HistoryStatus.empty => _HistoryMessage(
            icon: Icons.auto_stories_outlined,
            message: 'Tu bitácora está vacía. ¡Acepta una misión en Explorar para empezarla!',
            actionLabel: 'Volver',
            onAction: () => Navigator.of(context).pop(),
          ),
          HistoryStatus.data => _HistoryList(
            historyViewModel: historyViewModel,
            searchController: _searchController,
          ),
        },
      ),
    );
  }
}

class _HistoryList extends StatelessWidget {
  final MissionHistoryViewModel historyViewModel;
  final TextEditingController searchController;

  const _HistoryList({required this.historyViewModel, required this.searchController});

  @override
  Widget build(BuildContext context) {
    final history = historyViewModel.history;
    // Month headers and their missions, one flat list, so only what's on
    // screen gets built however long the history is.
    final rows = <Object>[
      for (final month in history.months) ...[month, ...month.entries],
    ];

    return RefreshIndicator(
      onRefresh: historyViewModel.load,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            sliver: SliverToBoxAdapter(
              child: _Controls(historyViewModel: historyViewModel, searchController: searchController),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
            sliver: rows.isEmpty
                ? const SliverToBoxAdapter(child: _NoMatches())
                : SliverList.builder(
                    itemCount: rows.length,
                    itemBuilder: (context, index) => switch (rows[index]) {
                      HistoryMonth month => _MonthHeader(month: month),
                      final HistoryEntry entry => _EntryCard(entry: entry),
                      _ => const SizedBox.shrink(),
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// Offline banner, search, filter chips and how many missions are shown.
class _Controls extends StatelessWidget {
  final MissionHistoryViewModel historyViewModel;
  final TextEditingController searchController;

  const _Controls({required this.historyViewModel, required this.searchController});

  static const _filterLabels = {
    HistoryFilter.all: 'Todas',
    HistoryFilter.completed: 'Completadas',
    HistoryFilter.abandoned: 'Abandonadas',
  };

  @override
  Widget build(BuildContext context) {
    final history = historyViewModel.history;
    final total = history.totalAttempts;
    final notice = historyViewModel.connectionNotice;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (notice != null) ...[
          _ConnectionBanner(
            notice: notice,
            pendingSyncCount: history.pendingSyncCount,
            lastSyncedAt: historyViewModel.lastSyncedAt,
          ),
          const SizedBox(height: 12),
        ],
        // Only the clear button follows the text as it's typed; the list
        // waits for the pause (MissionHistoryViewModel.setQuery).
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: searchController,
          builder: (context, value, _) => TextField(
            controller: searchController,
            onChanged: historyViewModel.setQuery,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Buscar misión, lugar o categoría',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: value.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Borrar búsqueda',
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        searchController.clear();
                        historyViewModel.setQuery('');
                      },
                    ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        // Wrap, not Row: like Explore's chips, so a small phone never overflows.
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final MapEntry(key: filter, value: label) in _filterLabels.entries)
              ChoiceChip(
                label: Text(label),
                selected: historyViewModel.filter == filter,
                onSelected: (_) => historyViewModel.setFilter(filter),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          historyViewModel.isNarrowed
              ? 'Mostrando ${history.matchCount} de $total ${total == 1 ? 'misión' : 'misiones'}'
              : '$total ${total == 1 ? 'misión' : 'misiones'} en tu bitácora',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 4),
        // Fixed height, so the list doesn't jump when the bar comes and goes.
        // Also while reloading: pull to refresh, or after reconnecting.
        SizedBox(
          height: 2,
          child: historyViewModel.isUpdating || historyViewModel.isRefreshing
              ? const LinearProgressIndicator()
              : null,
        ),
      ],
    );
  }
}

class _MonthHeader extends StatelessWidget {
  final HistoryMonth month;

  const _MonthHeader({required this.month});

  @override
  Widget build(BuildContext context) {
    final summary = [
      if (month.completedCount > 0) _count(month.completedCount, 'completada', 'completadas'),
      if (month.abandonedCount > 0) _count(month.abandonedCount, 'abandonada', 'abandonadas'),
      if (month.inProgressCount > 0) '${month.inProgressCount} en curso',
      if (month.completedMinutes > 0) '${month.completedMinutes} min',
      if (month.steps != null) _count(month.steps!, 'paso', 'pasos'),
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${_monthNamesEs[month.month - 1]} ${month.year}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (summary.isNotEmpty) Text(summary, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }

  static String _count(int value, String one, String many) =>
      '${formatThousands(value)} ${value == 1 ? one : many}';
}

class _EntryCard extends StatelessWidget {
  final HistoryEntry entry;

  const _EntryCard({required this.entry});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final quest = entry.quest;
    final details = [
      _formatShortDate(entry.date),
      if (quest != null) categoryLabelEs(quest.category),
      if (quest != null) '${quest.durationMinutes} min',
    ].join(' · ');

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        // A quest no longer in the catalogue has no detail to open.
        onTap: quest == null
            ? null
            : () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => QuestDetailView(quest: quest))),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(quest?.emoji ?? '🎯', style: const TextStyle(fontSize: 22)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.titleSmall,
                    ),
                    const SizedBox(height: 2),
                    Text(details, style: textTheme.bodySmall),
                    const SizedBox(height: 6),
                    _Outcome(entry: entry),
                    if (entry.steps != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        '🚶 ${formatThousands(entry.steps!)} ${entry.steps == 1 ? 'paso' : 'pasos'}',
                        style: textTheme.bodySmall,
                      ),
                    ],
                    // Changed offline (abandoned, rated…): the server gets it
                    // when the connection is back, and this mark goes away.
                    if (entry.isPendingSync) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(
                            Icons.cloud_upload_outlined,
                            size: 14,
                            color: Theme.of(context).colorScheme.outline,
                          ),
                          const SizedBox(width: 4),
                          Flexible(child: Text('Pendiente de sincronizar', style: textTheme.bodySmall)),
                        ],
                      ),
                    ],
                    // Evidencias de un intento (Alejandro, Sprint 4): the
                    // photos of this attempt. Its own tap target, so the
                    // card's onTap (the quest's detail) stays as it was.
                    TextButton.icon(
                      onPressed: () => Navigator.of(context).push(
                        AttemptEvidenceView.route(
                          EvidenceAttempt(
                            attemptId: entry.attemptId,
                            questId: entry.questId,
                            questTitle: entry.title,
                            date: entry.date,
                          ),
                        ),
                      ),
                      icon: const Icon(Icons.photo_library_outlined, size: 18),
                      label: const Text('Evidencias'),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                      ),
                    ),
                  ],
                ),
              ),
              if (quest != null) ...[
                const SizedBox(width: 4),
                Icon(Icons.chevron_right, color: Theme.of(context).colorScheme.outline),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// How the attempt ended: the stars given, why it was abandoned, or that
/// it's still going.
class _Outcome extends StatelessWidget {
  final HistoryEntry entry;

  const _Outcome({required this.entry});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    // The backend only accepts 1-5; clamped anyway so a bad row can't crash.
    final rating = entry.rating?.clamp(1, 5);
    final reason = _reasonFor(entry.abandonReason);

    final (label, color) = entry.isCompleted
        ? ('Completada', AppColors.secondary)
        : entry.isAbandoned
        ? ('Abandonada', AppColors.error)
        : ('En curso', AppColors.primary);

    return Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(label, style: textTheme.labelMedium?.copyWith(color: color, fontWeight: FontWeight.w700)),
        if (entry.isCompleted && rating != null)
          Semantics(
            label: 'Calificación: $rating de 5',
            child: ExcludeSemantics(
              child: Text(
                '★' * rating + '☆' * (5 - rating),
                style: textTheme.bodyMedium?.copyWith(color: AppColors.amber),
              ),
            ),
          )
        else if (entry.isCompleted)
          Text('Sin calificar', style: textTheme.bodySmall)
        else if (entry.isAbandoned && reason != null)
          Text('${reason.emoji} ${reason.label}', style: textTheme.bodySmall),
      ],
    );
  }

  /// Null for no reason, or a code this version doesn't know.
  static AbandonmentReason? _reasonFor(String? code) =>
      AbandonmentReason.values.where((reason) => reason.code == code).firstOrNull;
}

class _NoMatches extends StatelessWidget {
  const _NoMatches();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(color: Theme.of(context).cardColor, borderRadius: BorderRadius.circular(16)),
      child: Column(
        children: [
          Icon(Icons.search_off, size: 32, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 10),
          Text(
            'Ninguna misión coincide',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          Text(
            'Prueba con otra palabra o cambia el filtro.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// Where the list on screen comes from while it isn't the server's, fresh —
/// how old it is, and how many changes made offline are still waiting to go
/// out. Same look as StatsView's offline banner.
class _ConnectionBanner extends StatelessWidget {
  final HistoryConnectionNotice notice;
  final int pendingSyncCount;

  /// Saved on the device (MissionHistoryViewModel.lastSyncedAt); null hides it.
  final DateTime? lastSyncedAt;

  const _ConnectionBanner({required this.notice, required this.pendingSyncCount, this.lastSyncedAt});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textTheme = Theme.of(context).textTheme;
    final (icon, message) = switch (notice) {
      HistoryConnectionNotice.offline => (
        Icons.wifi_off,
        'Sin conexión: estás viendo tu bitácora guardada. Se actualizará sola cuando vuelva el internet.',
      ),
      HistoryConnectionNotice.syncing => (Icons.sync, 'Conectado: actualizando tu bitácora…'),
      HistoryConnectionNotice.serverUnreachable => (
        Icons.cloud_off,
        'No pudimos conectar con el servidor: estás viendo tu bitácora guardada. '
            'Desliza hacia abajo para reintentar.',
      ),
    };
    final pending = pendingSyncCount == 1
        ? '1 misión con cambios por sincronizar.'
        : '$pendingSyncCount misiones con cambios por sincronizar.';
    final syncedAt = lastSyncedAt;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? AppColors.primaryContainerDark : AppColors.primaryContainerLight,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: AppColors.primary, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(message, style: textTheme.bodySmall),
                if (syncedAt != null) ...[
                  const SizedBox(height: 4),
                  Text('Última actualización: ${_formatSyncedAt(syncedAt)}', style: textTheme.bodySmall),
                ],
                if (pendingSyncCount > 0) ...[
                  const SizedBox(height: 4),
                  Text(pending, style: textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HistoryMessage extends StatelessWidget {
  final IconData icon;
  final String message;
  final String actionLabel;
  final VoidCallback onAction;

  const _HistoryMessage({
    required this.icon,
    required this.message,
    required this.actionLabel,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 16),
            FilledButton(onPressed: onAction, child: Text(actionLabel)),
          ],
        ),
      ),
    );
  }
}

const _monthNamesEs = [
  'Enero', 'Febrero', 'Marzo', 'Abril', 'Mayo', 'Junio',
  'Julio', 'Agosto', 'Septiembre', 'Octubre', 'Noviembre', 'Diciembre',
];

const _monthAbbrEs = ['Ene', 'Feb', 'Mar', 'Abr', 'May', 'Jun', 'Jul', 'Ago', 'Sep', 'Oct', 'Nov', 'Dic'];

/// Same "Nov 12" as Perfil's "Completadas recientemente".
String _formatShortDate(DateTime date) => '${_monthAbbrEs[date.month - 1]} ${date.day}';

/// "Nov 12, 08:05", in the phone's time.
String _formatSyncedAt(DateTime date) {
  final local = date.toLocal();
  String twoDigits(int value) => value.toString().padLeft(2, '0');
  return '${_formatShortDate(local)}, ${twoDigits(local.hour)}:${twoDigits(local.minute)}';
}
