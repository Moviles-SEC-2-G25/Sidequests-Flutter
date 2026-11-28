import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
import '../../core/category_labels.dart';
import '../../data/services/location_service.dart';
import '../../data/services/weather_service.dart';
import '../../models/quest.dart';
import '../../models/user_quest.dart';
import '../../models/weather_snapshot.dart';
import '../../viewmodel/quests/quest_view_model.dart';
import '../widgets/offline_notice.dart';
import '../widgets/quest_address.dart';
import '../widgets/quest_compass.dart';
import '../widgets/sponsored_badge.dart';
import '../widgets/sq_components.dart';
import 'mission_tab_view.dart';

/// Quest detail: full info, a 2x2 stat grid, difficulty banner, step count
/// and the accept CTA — or, if the quest is already in progress/completed,
/// the matching state instead of a duplicate "accept" action.
class QuestDetailView extends StatefulWidget {
  final Quest quest;
  final bool wasRecommended;

  const QuestDetailView({super.key, required this.quest, this.wasRecommended = false});

  @override
  State<QuestDetailView> createState() => _QuestDetailViewState();
}

class _QuestDetailViewState extends State<QuestDetailView> {
  bool _isAccepting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => context.read<QuestViewModel>().loadSteps(widget.quest.id),
    );
  }

  Future<void> _accept() async {
    setState(() => _isAccepting = true);
    final questViewModel = context.read<QuestViewModel>();
    final accepted = await questViewModel.acceptQuest(
      widget.quest.id,
      wasRecommended: widget.wasRecommended,
    );
    if (!mounted) return;
    if (!accepted) {
      // Not started (e.g. offline): no mission to show, stay here.
      setState(() => _isAccepting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(questViewModel.errorMessage ?? 'Could not start the quest.')),
      );
      return;
    }
    Navigator.of(
      context,
    ).pushReplacement(MaterialPageRoute(builder: (_) => const MissionTabView(isTab: false)));
  }

  @override
  Widget build(BuildContext context) {
    final quest = widget.quest;
    final questViewModel = context.watch<QuestViewModel>();
    final UserQuest? userQuest = questViewModel.userQuests
        .cast<UserQuest?>()
        .firstWhere((uq) => uq?.questId == quest.id, orElse: () => null);
    // Abandoned is closed too: accepting the quest again is a new attempt.
    final isUnfinished =
        userQuest != null &&
        userQuest.status != 'completed' &&
        userQuest.status != 'skipped' &&
        userQuest.status != 'abandoned';
    final isCompleted = userQuest?.status == 'completed';
    final stepsForThisQuest = questViewModel.stepsOf(quest.id);
    final stepCount = stepsForThisQuest.isNotEmpty ? stepsForThisQuest.length : null;
    final stepsUnavailable = questViewModel.stepsUnavailableMessage(quest.id);
    final isOffline = watchIsOffline(context);

    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final faded = scheme.onSurface.withValues(alpha: .62);

    // Kotlin's QuestDetailScreen: "← Back", pills + category, emoji, title,
    // description, the four facts, difficulty, weather, compass, the steps
    // and the call to action, 16 dp apart.
    final sections = <Widget>[
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('← Back')),
      ),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (quest.isNew) SqMetaPill('New', color: AppColors.amber.withValues(alpha: .25)),
              if (quest.isSponsored) SponsoredBadge(sponsorName: quest.sponsorName, showSponsorName: true),
              if (quest.isGroup) const SqMetaPill('Group quest'),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  categoryLabelEs(quest.category).toUpperCase(),
                  style: textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(quest.emoji ?? '🎯', style: const TextStyle(fontSize: 36)),
          const SizedBox(height: 8),
          Text(quest.title, style: textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(quest.description, style: textTheme.bodyMedium),
          const SizedBox(height: 8),
          QuestAddress(quest: quest),
        ],
      ),
      _FactRow(
        children: [
          _QuestFact(emoji: '⏱', label: 'Duration', value: '${quest.durationMinutes} min'),
          _QuestFact(
            emoji: '💰',
            label: 'Est. cost',
            value: quest.estimatedCost > 0 ? '\$${quest.estimatedCost.toStringAsFixed(0)}' : 'Free',
          ),
        ],
      ),
      _FactRow(
        children: [
          _QuestFact(
            emoji: quest.locationMode == 'anywhere' ? '🏠' : '📍',
            label: 'Location',
            value: quest.locationName ?? (quest.locationMode == 'anywhere' ? 'Anywhere' : 'Nearby'),
          ),
          _QuestFact(emoji: '👥', label: 'Social', value: _socialLabel(quest.socialLevel)),
        ],
      ),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: scheme.secondaryContainer, borderRadius: BorderRadius.circular(16)),
        child: Text(
          'Difficulty: ${_difficultyLabel(quest.difficulty)}',
          style: textTheme.titleSmall?.copyWith(color: scheme.onSecondaryContainer),
        ),
      ),
      _WeatherCard(quest: quest),
      if (quest.latitude != null && quest.longitude != null) QuestCompass(quest: quest),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            stepCount != null ? "What you'll do ($stepCount steps)" : "What you'll do",
            style: textTheme.titleMedium,
          ),
          if (stepsUnavailable != null) ...[
            const SizedBox(height: 9),
            Text(stepsUnavailable, style: textTheme.bodyMedium),
          ],
          for (final (index, step) in stepsForThisQuest.indexed) ...[
            const SizedBox(height: 9),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 30,
                  height: 30,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.primary.withValues(alpha: .14),
                  ),
                  child: Text(
                    '${index + 1}',
                    style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w900),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(step.title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                      Text(step.description, style: textTheme.bodyMedium?.copyWith(color: faded)),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (isCompleted)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.secondary.withValues(alpha: .12),
                borderRadius: BorderRadius.circular(18),
              ),
              child: const Text(
                '✓ You already completed this quest',
                style: TextStyle(color: AppColors.secondary, fontWeight: FontWeight.w700),
              ),
            )
          else if (isUnfinished) ...[
            _InProgressCard(done: userQuest.completedSteps.length, total: stepCount),
            const SizedBox(height: 10),
            FilledButton(
              style: sqPrimaryButtonStyle(AppColors.secondary),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const MissionTabView(isTab: false)),
              ),
              child: const Text('Continue quest →'),
            ),
          ] else if (isOffline) ...[
            // Starting needs the server: blocked up front, saying why.
            const OfflineNotice(message: OfflineMessages.startMission),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: null,
              icon: const Icon(Icons.wifi_off, size: 18),
              label: const Text('Offline'),
            ),
          ] else
            FilledButton(
              onPressed: _isAccepting ? null : _accept,
              child: _isAccepting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('Accept quest →'),
            ),
        ],
      ),
    ];

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final (index, section) in sections.indexed) ...[
                if (index > 0) const SizedBox(height: 16),
                section,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Kotlin's "⚡ IN PROGRESS" card above "Continue quest →".
class _InProgressCard extends StatelessWidget {
  final int done;
  final int? total;

  const _InProgressCard({required this.done, required this.total});

  @override
  Widget build(BuildContext context) {
    final steps = total;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.secondary.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SqSectionLabel('⚡ IN PROGRESS', color: AppColors.secondary, fontSize: 11),
          const SizedBox(height: 6),
          Text(
            steps == null ? '$done steps completed' : '$done of $steps steps completed',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          if (steps != null && steps > 0) ...[
            const SizedBox(height: 6),
            SqProgressBar(value: done / steps, height: 6),
          ],
        ],
      ),
    );
  }
}

/// "Clima en el lugar": weather at the quest's coordinates, or at the user's
/// position for 'anywhere' quests / quests without coordinates. Renders
/// nothing while loading or without a position to ask about; says so when no
/// weather could be obtained, and how old it is when it's a last known value.
class _WeatherCard extends StatefulWidget {
  final Quest quest;

  const _WeatherCard({required this.quest});

  @override
  State<_WeatherCard> createState() => _WeatherCardState();
}

class _WeatherCardState extends State<_WeatherCard> {
  /// The rain probability is a forecast of the 3 h after it was fetched.
  static const _rainForecastMaxAge = Duration(hours: 3);

  WeatherSnapshot? _weather;
  bool _isUnavailable = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final locationService = context.read<LocationService>();
    final weatherService = context.read<WeatherService>();
    final quest = widget.quest;

    double? latitude = quest.latitude;
    double? longitude = quest.longitude;
    WeatherSnapshot? weather;
    try {
      if (quest.locationMode == 'anywhere' || latitude == null || longitude == null) {
        final position = await locationService.getCurrentPosition();
        latitude = position?.latitude;
        longitude = position?.longitude;
      }
      if (latitude == null || longitude == null) return;
      weather = await weatherService.fetch(latitude, longitude);
    } catch (_) {
      // A location sensor that failed: same as no weather.
    }
    if (!mounted) return;
    setState(() {
      _weather = weather;
      _isUnavailable = weather == null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final weather = _weather;
    final textTheme = Theme.of(context).textTheme;
    // Kotlin's WeatherReadingCard: a plain 16 dp card with a titleSmall title.
    final quest = widget.quest;
    final title = quest.locationMode == 'gps' && quest.latitude != null && quest.longitude != null
        ? 'Weather at the location'
        : 'Weather near you';
    if (weather == null && !_isUnavailable) return const SizedBox.shrink();

    final lines = <Widget>[Text(title, style: textTheme.titleSmall)];
    if (weather == null) {
      lines.add(Text('Weather not available offline', style: textTheme.bodyLarge));
    } else {
      final rainChance = weather.maxPrecipitationProbability;
      final age = DateTime.now().difference(weather.fetchedAt);
      final showRainChance = !weather.isStale || age <= _rainForecastMaxAge;
      lines.add(Text('${weather.temperatureC.round()}°C · ${weather.description}', style: textTheme.bodyLarge));
      if (showRainChance) lines.add(Text('Rain in the next 3 h: $rainChance%', style: textTheme.bodySmall));
      if (weather.isStale) {
        lines.add(Text('Last update: ${age.inMinutes} min ago · offline', style: textTheme.bodySmall));
      }
    }
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: SizedBox(
          width: double.infinity,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final (index, line) in lines.indexed) ...[if (index > 0) const SizedBox(height: 5), line],
            ],
          ),
        ),
      ),
    );
  }
}

/// Two facts side by side, as tall as the taller one ("Solo — just you"
/// wraps on a 360 dp phone or with a larger system font).
class _FactRow extends StatelessWidget {
  final List<Widget> children;

  const _FactRow({required this.children});

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: children[0]),
          const SizedBox(width: 10),
          Expanded(child: children.length > 1 ? children[1] : const SizedBox()),
        ],
      ),
    );
  }
}

/// Kotlin's QuestFact: bordered card, emoji, a tiny uppercase label and the value.
class _QuestFact extends StatelessWidget {
  final String emoji;
  final String label;
  final String value;

  const _QuestFact({required this.emoji, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return SqOutlinedCard(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Text(emoji, style: const TextStyle(fontSize: 22)),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  label.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 9, fontWeight: FontWeight.w900, color: onSurface.withValues(alpha: .45)),
                ),
                Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _difficultyLabel(String difficulty) => switch (difficulty) {
  'easy' => 'Easy',
  'medium' => 'Medium',
  'hard' => 'Hard',
  _ => difficulty,
};

String _socialLabel(String socialLevel) => switch (socialLevel) {
  'solo' => 'Solo',
  'social' => 'Social',
  'group' => 'Group',
  _ => socialLevel,
};
