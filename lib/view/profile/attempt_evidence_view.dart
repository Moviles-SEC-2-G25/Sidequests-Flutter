import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
import '../../repository/evidence_repository.dart';
import '../../viewmodel/context/connectivity_view_model.dart';
import '../../viewmodel/profile/attempt_evidence_view_model.dart';
import '../widgets/offline_notice.dart';
import '../widgets/sq_components.dart';

/// "Evidencias de un intento" (Alejandro, Sprint 4), opened from a card of Mi
/// bitácora: the photos taken in that attempt, grouped by step, each with
/// where it can be seen from (saved on the phone, available on reconnect,
/// pending upload), a full-screen viewer with zoom and swipe, and "Guardar
/// todas en el teléfono". Everything it shows comes from
/// AttemptEvidenceViewModel: this file never touches Supabase, files or
/// isolates.
class AttemptEvidenceView extends StatefulWidget {
  final EvidenceAttempt attempt;

  const AttemptEvidenceView({super.key, required this.attempt});

  /// Scoped to this route, like Mi bitácora's: a fresh ViewModel per visit,
  /// disposed (cancelling what's still waiting to download) when it closes.
  static Route<void> route(EvidenceAttempt attempt) => MaterialPageRoute(
    builder: (context) => ChangeNotifierProvider(
      create: (context) => AttemptEvidenceViewModel(
        context.read<EvidenceRepository>(),
        attempt: attempt,
        connectivity: context.read<ConnectivityViewModel?>(),
      ),
      child: AttemptEvidenceView(attempt: attempt),
    ),
  );

  @override
  State<AttemptEvidenceView> createState() => _AttemptEvidenceViewState();
}

class _AttemptEvidenceViewState extends State<AttemptEvidenceView> {
  @override
  void initState() {
    super.initState();
    // Not in the provider's `create`: load() notifies right away.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AttemptEvidenceViewModel>().load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<AttemptEvidenceViewModel>();
    final textTheme = Theme.of(context).textTheme;

    final scheme = Theme.of(context).colorScheme;
    // Kotlin's AttemptEvidenceScreen header, compacted to one row: the
    // bordered round back button, the section label, the quest and the date.
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Row(
                children: [
                  Material(
                    color: scheme.surface,
                    shape: CircleBorder(side: BorderSide(color: scheme.outline)),
                    child: IconButton(
                      tooltip: 'Back to Mission History',
                      icon: const Icon(Icons.arrow_back, size: 20),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SqSectionLabel('ATTEMPT EVIDENCE', color: scheme.primary, letterSpacing: .8),
                        Text(
                          widget.attempt.questTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        Text(
                          'Attempt on ${formatEvidenceDate(widget.attempt.date)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(child: _body(context, viewModel)),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context, AttemptEvidenceViewModel viewModel) {
    return switch (viewModel.status) {
          EvidenceStatus.loading => const Center(child: CircularProgressIndicator()),
          EvidenceStatus.empty => _EvidenceMessage(
            icon: Icons.photo_library_outlined,
            message: 'This attempt has no photos',
            actionLabel: 'Back',
            onAction: () => Navigator.of(context).pop(),
          ),
          EvidenceStatus.error => _EvidenceMessage(
            icon: viewModel.isOffline ? Icons.wifi_off : Icons.cloud_off,
            message: viewModel.errorMessage ?? 'The photos for this attempt could not be loaded.',
            actionLabel: 'Retry',
            onAction: viewModel.load,
          ),
          EvidenceStatus.data => _EvidenceGrid(viewModel: viewModel),
        };
  }
}

class _EvidenceGrid extends StatelessWidget {
  final AttemptEvidenceViewModel viewModel;

  const _EvidenceGrid({required this.viewModel});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    // Each group's first page in the viewer, which shows every photo in this
    // same order.
    final firstIndexes = <int>[];
    var count = 0;
    for (final group in viewModel.groups) {
      firstIndexes.add(count);
      count += group.items.length;
    }

    return RefreshIndicator(
      onRefresh: viewModel.load,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            sliver: SliverToBoxAdapter(child: _Header(viewModel: viewModel)),
          ),
          for (final (index, group) in viewModel.groups.indexed) ...[
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
              sliver: SliverToBoxAdapter(child: Text(group.label, style: textTheme.titleSmall)),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              sliver: _groupGrid(group, firstIndexes[index]),
            ),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
        ],
      ),
    );
  }

  Widget _groupGrid(EvidenceStepGroup group, int firstIndex) => SliverGrid.builder(
    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: 130,
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
    ),
    itemCount: group.items.length,
    itemBuilder: (context, index) => _EvidenceTile(
      viewModel: viewModel,
      item: group.items[index],
      number: index + 1,
      stepLabel: group.label,
      onOpen: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (_) => ChangeNotifierProvider.value(
            value: viewModel,
            child: _EvidenceViewer(initialIndex: firstIndex + index),
          ),
        ),
      ),
    ),
  );
}

/// Offline notice, what the list couldn't load, and "Guardar todas".
class _Header extends StatelessWidget {
  final AttemptEvidenceViewModel viewModel;

  const _Header({required this.viewModel});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final pending = viewModel.pendingCount;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (viewModel.isOffline) ...[
          const OfflineNotice(message: OfflineMessages.attemptEvidence),
          const SizedBox(height: 12),
        ],
        if (viewModel.uploadedListMissing) ...[
          Text(
            'The photos you already uploaded for this attempt will appear when you are back online.',
            style: textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
        ],
        if (pending > 0) ...[
          Text(
            pending == 1
                ? '1 photo waiting to upload: it will upload automatically when you are online.'
                : '$pending photos waiting to upload: they will upload automatically when you are online.',
            style: textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
        ],
        if (viewModel.canSavePhotos && viewModel.uploadedCount > 0) _SaveAllPanel(viewModel: viewModel),
        // Fixed height, so the grid doesn't jump while it refreshes.
        SizedBox(height: 2, child: viewModel.isSyncing ? const LinearProgressIndicator() : null),
      ],
    );
  }
}

class _SaveAllPanel extends StatelessWidget {
  final AttemptEvidenceViewModel viewModel;

  const _SaveAllPanel({required this.viewModel});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final saved = viewModel.savedCount;
    final total = viewModel.uploadedCount;
    final failed = viewModel.saveFailed;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? AppColors.primaryContainerDark : AppColors.primaryContainerLight,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.offline_pin_outlined, color: Theme.of(context).colorScheme.primary, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '$saved of $total ${total == 1 ? 'photo saved' : 'photos saved'} on the phone',
                  style: textTheme.bodySmall,
                ),
              ),
            ],
          ),
          if (viewModel.isSaving) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: viewModel.saveTotal == 0 ? null : viewModel.saveDone / viewModel.saveTotal,
            ),
            const SizedBox(height: 4),
            Text('Saving ${viewModel.saveDone} of ${viewModel.saveTotal}…', style: textTheme.bodySmall),
          ] else if (failed > 0) ...[
            const SizedBox(height: 4),
            Text(
              failed == 1 ? '1 photo could not be saved.' : '$failed photos could not be saved.',
              style: textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton.tonalIcon(
              onPressed: viewModel.canSaveAll ? viewModel.saveAll : null,
              icon: Icon(viewModel.allSaved ? Icons.check : Icons.download_outlined),
              label: Text(viewModel.allSaved ? 'All saved on phone' : 'Save all to phone'),
            ),
          ),
        ],
      ),
    );
  }
}

class _EvidenceTile extends StatelessWidget {
  final AttemptEvidenceViewModel viewModel;
  final EvidenceItem item;
  final int number;
  final String stepLabel;
  final VoidCallback onOpen;

  const _EvidenceTile({
    required this.viewModel,
    required this.item,
    required this.number,
    required this.stepLabel,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    // Only tiles being built ask: what's off screen doesn't download.
    viewModel.ensureThumbnail(item.id);
    final availability = viewModel.availabilityOf(item.id);
    final thumbnail = viewModel.thumbnailOf(item.id);
    final colorScheme = Theme.of(context).colorScheme;
    final status = _statusLabel(availability, viewModel.errorOf(item.id));

    return Semantics(
      button: true,
      label: '$stepLabel, photo $number${status == null ? '' : ': $status'}',
      child: ExcludeSemantics(
        child: Material(
          color: colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: availability == EvidenceAvailability.failed ? () => viewModel.retry(item.id) : onOpen,
            child: LayoutBuilder(
              builder: (context, constraints) {
                // Decoded at the cell's size in pixels, never the photo's.
                final cacheWidth = (constraints.maxWidth * MediaQuery.devicePixelRatioOf(context)).round();
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    if (thumbnail != null)
                      Image.memory(
                        thumbnail,
                        fit: BoxFit.cover,
                        cacheWidth: cacheWidth > 0 ? cacheWidth : null,
                        gaplessPlayback: true,
                        errorBuilder: (_, _, _) => Icon(Icons.broken_image_outlined, color: colorScheme.onSurfaceVariant),
                      )
                    else if (viewModel.isThumbnailLoading(item.id))
                      const Center(
                        child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                      )
                    else
                      Center(child: Icon(_placeholderIcon(availability), color: colorScheme.onSurfaceVariant)),
                    if (availability == EvidenceAvailability.onPhone)
                      const Positioned(top: 6, right: 6, child: _SavedBadge()),
                    if (status != null && availability != EvidenceAvailability.onPhone)
                      Positioned(left: 0, right: 0, bottom: 0, child: _StatusStrip(availability, status)),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  static IconData _placeholderIcon(EvidenceAvailability availability) => switch (availability) {
    EvidenceAvailability.availableOnReconnect => Icons.cloud_off_outlined,
    EvidenceAvailability.failed => Icons.refresh,
    _ => Icons.image_outlined,
  };
}

/// What each state says, on the tile and in the viewer.
String? _statusLabel(EvidenceAvailability availability, String? error) => switch (availability) {
  EvidenceAvailability.onPhone => 'Saved on phone',
  EvidenceAvailability.availableOnReconnect => 'Available when back online',
  EvidenceAvailability.pendingUpload => 'Waiting to upload',
  EvidenceAvailability.failed => error ?? 'Could not load. Tap to retry.',
  EvidenceAvailability.inCloud => null,
};

class _SavedBadge extends StatelessWidget {
  const _SavedBadge();

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Saved on phone',
    child: Container(
      padding: const EdgeInsets.all(3),
      decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
      child: const Icon(Icons.offline_pin, size: 16, color: Colors.white),
    ),
  );
}

class _StatusStrip extends StatelessWidget {
  final EvidenceAvailability availability;
  final String label;

  const _StatusStrip(this.availability, this.label);

  @override
  Widget build(BuildContext context) {
    final icon = switch (availability) {
      EvidenceAvailability.pendingUpload => Icons.cloud_upload_outlined,
      EvidenceAvailability.availableOnReconnect => Icons.cloud_off_outlined,
      _ => Icons.refresh,
    };
    return Container(
      color: Colors.black54,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 12, color: Colors.white),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}

/// Full screen, one photo per page: pinch to zoom (InteractiveViewer), swipe
/// for the next one. Paging is off while zoomed in, so a pan moves the photo
/// instead of changing page.
class _EvidenceViewer extends StatefulWidget {
  final int initialIndex;

  const _EvidenceViewer({required this.initialIndex});

  @override
  State<_EvidenceViewer> createState() => _EvidenceViewerState();
}

class _EvidenceViewerState extends State<_EvidenceViewer> {
  late final PageController _controller = PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;
  bool _zoomed = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<AttemptEvidenceViewModel>();
    final items = viewModel.items;
    if (items.isEmpty) return const Scaffold(backgroundColor: Colors.black);
    final current = items[_index.clamp(0, items.length - 1)];

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(viewModel.stepLabelOf(current), maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(
              '${_index + 1} of ${items.length}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.white70),
            ),
          ],
        ),
      ),
      body: PageView.builder(
        controller: _controller,
        physics: _zoomed ? const NeverScrollableScrollPhysics() : null,
        itemCount: items.length,
        onPageChanged: (index) => setState(() {
          _index = index;
          _zoomed = false;
        }),
        itemBuilder: (context, index) => _ViewerPage(
          key: ValueKey(items[index].id),
          item: items[index],
          onZoomChanged: (zoomed) {
            if (zoomed != _zoomed) setState(() => _zoomed = zoomed);
          },
        ),
      ),
    );
  }
}

class _ViewerPage extends StatefulWidget {
  final EvidenceItem item;
  final ValueChanged<bool> onZoomChanged;

  const _ViewerPage({super.key, required this.item, required this.onZoomChanged});

  @override
  State<_ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<_ViewerPage> {
  final _transform = TransformationController();

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<AttemptEvidenceViewModel>();
    final id = widget.item.id;
    viewModel.ensurePhoto(id);
    final photo = viewModel.photoOf(id);
    final thumbnail = viewModel.thumbnailOf(id);
    final availability = viewModel.availabilityOf(id);
    final status = _statusLabel(availability, viewModel.errorOf(id));
    // Twice the screen's pixels, so zooming in stays sharp without ever
    // decoding a 25 MB photo at full size.
    final size = MediaQuery.sizeOf(context);
    final cacheWidth = (size.width * MediaQuery.devicePixelRatioOf(context) * 2).round();

    final Widget content;
    if (photo != null) {
      content = InteractiveViewer(
        transformationController: _transform,
        minScale: 1,
        maxScale: 5,
        onInteractionEnd: (_) => widget.onZoomChanged(_transform.value.getMaxScaleOnAxis() > 1.01),
        child: Center(
          child: Image.memory(
            photo,
            fit: BoxFit.contain,
            cacheWidth: cacheWidth > 0 ? cacheWidth : null,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => const _ViewerMessage(
              icon: Icons.broken_image_outlined,
              title: 'Could not display this photo',
            ),
          ),
        ),
      );
    } else if (availability == EvidenceAvailability.availableOnReconnect) {
      content = const _ViewerMessage(
        icon: Icons.cloud_off_outlined,
        title: 'Available when back online',
        message: 'This photo is not saved on the phone. It will download when you are back online.',
      );
    } else if (availability == EvidenceAvailability.failed) {
      content = _ViewerMessage(
        icon: Icons.error_outline,
        title: viewModel.errorOf(id) ?? 'Could not load this photo.',
        actionLabel: 'Retry',
        onAction: () => viewModel.retry(id),
      );
    } else {
      // The thumbnail stands in, enlarged, until the photo arrives.
      content = Stack(
        fit: StackFit.expand,
        children: [
          if (thumbnail != null)
            Image.memory(
              thumbnail,
              fit: BoxFit.contain,
              cacheWidth: cacheWidth > 0 ? cacheWidth : null,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          const Center(child: CircularProgressIndicator(color: Colors.white)),
        ],
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        content,
        if (status != null &&
            (availability == EvidenceAvailability.onPhone || availability == EvidenceAvailability.pendingUpload))
          Positioned(
            left: 16,
            bottom: 16,
            child: SafeArea(
              child: Chip(
                avatar: Icon(
                  availability == EvidenceAvailability.onPhone ? Icons.offline_pin : Icons.cloud_upload_outlined,
                  size: 16,
                ),
                label: Text(status),
              ),
            ),
          ),
      ],
    );
  }
}

class _ViewerMessage extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _ViewerMessage({required this.icon, required this.title, this.message, this.actionLabel, this.onAction});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: Colors.white70),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: textTheme.titleMedium?.copyWith(color: Colors.white),
            ),
            if (message != null) ...[
              const SizedBox(height: 6),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: textTheme.bodySmall?.copyWith(color: Colors.white70),
              ),
            ],
            if (actionLabel != null) ...[
              const SizedBox(height: 16),
              FilledButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}

class _EvidenceMessage extends StatelessWidget {
  final IconData icon;
  final String message;
  final String actionLabel;
  final VoidCallback onAction;

  const _EvidenceMessage({
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
            Icon(icon, size: 48, color: Theme.of(context).colorScheme.onSurfaceVariant),
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
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

/// "12 de noviembre de 2026".
String formatEvidenceDate(DateTime date) => '${_monthNamesEs[date.month - 1]} ${date.day}, ${date.year}';
