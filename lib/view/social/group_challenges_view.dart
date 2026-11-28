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

    return Scaffold(
      appBar: AppBar(
        actions: [
          IconButton(
            tooltip: 'Actualizar',
            onPressed: viewModel.canRefresh ? viewModel.refresh : null,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: viewModel.refresh,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
            children: [
              Text('Retos en grupo', style: textTheme.headlineSmall),
              const SizedBox(height: 4),
              Text('Pequeñas aventuras, mejor en compañía.', style: textTheme.bodyMedium),
              const SizedBox(height: 16),
              if (viewModel.hasMine) ...[
                Row(
                  children: [
                    Expanded(
                      child: _Metric(
                        icon: '👥',
                        value: viewModel.joinedCount,
                        label: viewModel.joinedCount == 1 ? 'Reto unido' : 'Retos unidos',
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _Metric(
                        icon: '✓',
                        value: viewModel.completedSteps,
                        label: viewModel.completedSteps == 1 ? 'Paso completado' : 'Pasos completados',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
              const _Notice(
                icon: Icons.lock_outline,
                text:
                    'Se comparte durante 7 días con usuarios con sesión iniciada. Tus pasos son '
                    'auto-reportados y no cuentan en tu historial individual. Solo se comparten '
                    'conteos del grupo.',
              ),
              ..._statusNotices(context, viewModel),
              if (viewModel.isFirstLoad)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 48),
                  child: Center(child: CircularProgressIndicator()),
                )
              else ...[
                const SizedBox(height: 20),
                _SectionTitle('Mis retos', count: viewModel.hasMine ? viewModel.mine.length : null),
                const SizedBox(height: 10),
                if (!viewModel.hasMine)
                  const _EmptyCard(
                    icon: '☁️',
                    title: 'Lista no disponible',
                    description: 'Conéctate para ver tus retos.',
                  )
                else if (viewModel.mine.isEmpty)
                  const _EmptyCard(
                    icon: '👥',
                    title: 'Aún no estás en ningún reto',
                    description: 'Únete a uno abierto o crea uno abajo.',
                  ),
                for (final challenge in viewModel.mine)
                  _MyChallengeCard(challenge: challenge, viewModel: viewModel),
                const SizedBox(height: 20),
                _SectionTitle(
                  'Retos disponibles',
                  count: viewModel.hasAvailable ? viewModel.available.length : null,
                ),
                const SizedBox(height: 10),
                if (!viewModel.hasAvailable)
                  const _EmptyCard(
                    icon: '☁️',
                    title: 'Lista no disponible',
                    description: 'Conéctate para ver los retos abiertos.',
                  )
                else if (viewModel.available.isEmpty)
                  const _EmptyCard(
                    icon: '🌐',
                    title: 'No hay otros retos abiertos',
                    description: 'Puedes crear uno abajo.',
                  ),
                for (final challenge in viewModel.available)
                  _AvailableChallengeCard(challenge: challenge, viewModel: viewModel),
                const SizedBox(height: 20),
                _SectionTitle('Crear un reto', count: creatable.length),
                const SizedBox(height: 10),
                if (creatable.isEmpty)
                  const _EmptyCard(
                    icon: '＋',
                    title: 'No hay misiones en grupo nuevas para crear',
                    description: 'Tus retos siguen en Mis retos.',
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
          viewModel.isSubmitting ? 'Enviando solicitud…' : 'Actualizando retos…',
          style: Theme.of(context).textTheme.labelMedium,
        ),
      ],
      if (viewModel.someListsFailed && !viewModel.isOffline && !viewModel.busy) ...[
        const SizedBox(height: 12),
        _Notice(
          icon: Icons.cloud_off,
          text: 'Algunas listas no se pudieron actualizar. Se muestran las últimas guardadas.',
          actionLabel: 'Reintentar',
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
            Expanded(child: Text('Tu progreso', style: textTheme.titleSmall)),
            Text(
              '$percent%',
              style: textTheme.titleSmall?.copyWith(color: AppColors.primary, fontWeight: FontWeight.w700),
            ),
          ],
        ),
        LinearProgressIndicator(
          value: challenge.progressFraction,
          minHeight: 6,
          borderRadius: BorderRadius.circular(3),
        ),
        Text(
          '${challenge.progress} de ${challenge.totalSteps} pasos completados',
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
                  'SIGUIENTE PASO · ${challenge.progress + 1}',
                  style: textTheme.labelSmall?.copyWith(
                    color: AppColors.primary,
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
            child: Text(challenge.isCompleted ? 'Completado' : 'Marcar siguiente paso'),
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
            _Pill(challenge.totalSteps == 1 ? '1 paso' : '${challenge.totalSteps} pasos'),
          ],
        ),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: viewModel.canWrite ? () => viewModel.joinChallenge(challenge) : null,
            child: const Text('Unirme'),
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
            child: const Text('Crear reto'),
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
      GroupAction.create => 'Crear reto',
      GroupAction.join => 'Unirte al reto',
      GroupAction.progress => 'Marcar el paso ${action.progressValue ?? ''}',
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
              label: const Text('Reintentar solicitud pendiente'),
            ),
          ),
        ],
      ),
    );
  }
}

String _participantLabel(int count) => count == 1 ? '1 participante' : '$count participantes';

String _finishedLabel(int count) => count == 1 ? '1 terminó' : '$count terminaron';

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
          Text(icon, style: textTheme.titleLarge?.copyWith(color: AppColors.primary)),
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
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
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
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: Theme.of(context).colorScheme.outline),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: Theme.of(context).textTheme.bodySmall)),
          if (actionLabel != null)
            TextButton(onPressed: onAction, child: Text(actionLabel!)),
        ],
      ),
    );
  }
}
