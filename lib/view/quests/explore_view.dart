import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
import '../../core/category_labels.dart';
import '../../core/completion_likelihood.dart';
import '../../models/app_context.dart';
import '../../models/quest.dart';
import '../../models/quest_recommendation.dart';
import '../../viewmodel/profile/profile_view_model.dart';
import '../../viewmodel/quests/quest_view_model.dart';
import '../../viewmodel/theme_view_model.dart';
import '../social/group_challenges_view.dart';
import '../widgets/completion_likelihood_label.dart';
import '../widgets/offline_notice.dart';
import '../widgets/sponsored_badge.dart';
import '../widgets/sq_components.dart';
import 'mission_tab_view.dart';
import 'quest_detail_view.dart';

/// The "Explorar" tab: greeting, time/scope filters, a "continue where you
/// left off" banner, AI-personalized recommendations (backed by the shared
/// `recommend_quests` RPC / BQ5), "Descubre más" (Retos en grupo), and the
/// full filterable catalogue below.
class ExploreView extends StatefulWidget {
  /// Builds "Todas las misiones" as the old eager Column (every row built
  /// and laid out on each rebuild). Only for measuring the micro-optimization
  /// against its baseline; see [kExploreEagerList].
  final bool eagerMissionList;

  const ExploreView({super.key, this.eagerMissionList = kExploreEagerList});

  @override
  State<ExploreView> createState() => _ExploreViewState();
}

/// `--dart-define=EXPLORE_EAGER_LIST=true` puts back the eager mission list,
/// to compare before/after in the same build on the phone. Off by default.
const kExploreEagerList = bool.fromEnvironment('EXPLORE_EAGER_LIST');

/// Debug/profile-only counters for the Explore micro-optimization. Every
/// call site is behind `if (!kReleaseMode)`, a compile-time constant, so
/// release builds drop them.
abstract final class ExploreBuildStats {
  /// ExploreView builds since the last [reset].
  static int exploreBuilds = 0;

  /// `_QuestRow` builds since the last [reset], scrolling included.
  static int questRowBuilds = 0;

  /// Rows built in the frame of the last ExploreView rebuild (its build
  /// plus the layout that follows, where a lazy list builds its rows).
  static int lastRebuildRows = 0;

  static bool _frameScheduled = false;
  static int _rowsAtBuild = 0;

  static void reset() {
    exploreBuilds = 0;
    questRowBuilds = 0;
    lastRebuildRows = 0;
    _rowsAtBuild = 0;
    _frameScheduled = false;
  }

  static void _onExploreBuild() {
    exploreBuilds++;
    if (_frameScheduled) return;
    _frameScheduled = true;
    _rowsAtBuild = questRowBuilds;
    final rebuild = exploreBuilds;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _frameScheduled = false;
      lastRebuildRows = questRowBuilds - _rowsAtBuild;
      debugPrint('MicroOpt Explore: rebuild #$rebuild → quest rows built: $lastRebuildRows');
    });
  }
}

class _ExploreViewState extends State<ExploreView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadAll());
  }

  Future<void> _loadAll() async {
    final questViewModel = context.read<QuestViewModel>();
    final profileViewModel = context.read<ProfileViewModel>();
    await Future.wait([questViewModel.load(), profileViewModel.load()]);
    if (!mounted) return;
    questViewModel.showSavedRecommendationsIfOffline();
    await questViewModel.loadRecommendations(profileViewModel.preferences);
  }

  String get _greeting {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning';
    if (hour < 19) return 'Good afternoon';
    return 'Good evening';
  }

  /// Micro-optimization (Alejandro, Sprint 4): lazy "Todas las misiones".
  ///
  /// Problem: the body was a ListView whose last child was one Column with
  /// every mission of [QuestViewModel.filteredCatalog]. Explore watches the
  /// whole ViewModel, so each notify (a filter chip, a recommendations load,
  /// the context) rebuilt and laid out ALL the rows, on screen or not: 200
  /// missions meant 200 `_QuestRow`s (Card + ListTile + Texts) per rebuild,
  /// to show about 5. And filteredCatalog, which filters and re-sorts the
  /// catalogue each time it's read, was read 3 times per build.
  ///
  /// Change: the body is a CustomScrollView. The sections above are one box
  /// of keyed children (same keys, so the banners appearing don't recreate
  /// their State; they're few and always built), and the missions are a
  /// SliverList.builder that
  /// builds only the rows inside the viewport plus its cache extent; the
  /// rest are built when scrolled to. filteredCatalog is read once per
  /// build and passed down. No itemExtent/prototypeItem: a row is taller
  /// when sponsored or when its title wraps.
  ///
  /// Not the same as Lucas's RepaintBoundary on the compass (that limits
  /// what is *repainted* on each heading) nor Julián's missionSteps
  /// notifier (that limits *which widgets* are notified of a step) or his
  /// CompletionLikelihoodMemo (caching a result across builds). This one
  /// limits *how many widgets are built and laid out* when Explore does
  /// rebuild, and caches nothing between builds.
  ///
  /// `--dart-define=EXPLORE_EAGER_LIST=true` brings back the eager Column to
  /// measure against; [ExploreBuildStats] counts rows per rebuild.
  @override
  Widget build(BuildContext context) {
    if (!kReleaseMode) ExploreBuildStats._onExploreBuild();
    final questViewModel = context.watch<QuestViewModel>();
    final profileViewModel = context.watch<ProfileViewModel>();
    // Once per build: every read filters and re-sorts the whole catalogue.
    final missions = questViewModel.filteredCatalog;
    final likelihoodByCategory = questViewModel.completionLikelihoodByCategory;

    Widget missionRow(BuildContext context, Quest quest) => Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: _QuestRow(
        quest: quest,
        distanceKm: questViewModel.distanceKmTo(quest),
        completionLevel: questViewModel.completionLevelFor(quest, likelihoodByCategory),
        progressLabel: _progressLabel(questViewModel, quest),
        onTap: () {
          questViewModel.registerInteraction();
          Navigator.of(context).push(MaterialPageRoute(builder: (_) => QuestDetailView(quest: quest)));
        },
      ),
    );

    final missionsHeader = _AllMissionsHeader(
      questViewModel: questViewModel,
      missions: missions,
    );

    // Keyed so a conditional insertion above (the "continue" banner
    // appearing/disappearing) can't shift these to a new list slot and,
    // since a sliver list reconciles unkeyed children positionally,
    // silently dispose+recreate their State mid-interaction.
    final sections = <Widget>[
      ..._topSections(questViewModel, profileViewModel),
      if (widget.eagerMissionList)
        // The baseline: one box with every row, built and laid out whole.
        Column(
          key: const ValueKey('all-missions'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [missionsHeader, for (final quest in missions) missionRow(context, quest)],
        )
      else
        KeyedSubtree(key: const ValueKey('all-missions'), child: missionsHeader),
    ];

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _loadAll,
          child: CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
                sliver: SliverToBoxAdapter(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: sections),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                sliver: SliverList.builder(
                  itemCount: widget.eagerMissionList ? 0 : missions.length,
                  itemBuilder: (context, index) => missionRow(context, missions[index]),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Kotlin's "In progress · 2/4" pill, for the quest the user has open.
  static String? _progressLabel(QuestViewModel questViewModel, Quest quest) {
    final mission = questViewModel.currentMission;
    if (mission == null || mission.questId != quest.id) return null;
    final total = questViewModel.stepsOf(quest.id).length;
    if (total == 0) return 'In progress';
    return 'In progress · ${mission.completedSteps.length}/$total';
  }

  /// Everything above the catalogue, in the Kotlin ExplorerScreen's order.
  List<Widget> _topSections(QuestViewModel questViewModel, ProfileViewModel profileViewModel) => [
    if (questViewModel.currentMission != null) ...[
      const SizedBox(height: 12),
      _ContinueBanner(
        key: const ValueKey('continue-banner'),
        userQuestId: questViewModel.currentMission!.questId,
      ),
    ],
    const SizedBox(height: 18),
    _Header(
      key: const ValueKey('header'),
      greeting: _greeting,
      displayName: profileViewModel.profile?.displayName,
    ),
    const SizedBox(height: 20),
    _TimeAndScopeFilters(
      key: const ValueKey('filters'),
      questViewModel: questViewModel,
      profileViewModel: profileViewModel,
    ),
    const SizedBox(height: 12),
    _SocialMoodFilter(
      key: const ValueKey('social-mood'),
      questViewModel: questViewModel,
      profileViewModel: profileViewModel,
    ),
    const SizedBox(height: 32),
    _LiveContextCard(key: const ValueKey('live-context'), questViewModel: questViewModel),
    const SizedBox(height: 14),
    const _DiscoverMoreSection(key: ValueKey('discover-more')),
    if (questViewModel.isAdaptingToContext) ...[
      const SizedBox(height: 14),
      _ContextAdaptationBanner(
        key: const ValueKey('context-adaptation-banner'),
        appContext: questViewModel.currentContext!,
      ),
    ],
    const SizedBox(height: 14),
    _RecommendedSection(
      key: const ValueKey('recommended'),
      questViewModel: questViewModel,
      profileViewModel: profileViewModel,
    ),
  ];
}

/// Greeting, "What do you feel like today?" and Kotlin's round 🌙/☀️ toggle.
class _Header extends StatelessWidget {
  final String greeting;
  final String? displayName;

  const _Header({super.key, required this.greeting, this.displayName});

  @override
  Widget build(BuildContext context) {
    final themeViewModel = context.watch<ThemeViewModel?>();
    final name = displayName?.trim();
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                (name?.isNotEmpty ?? false) ? '$greeting, $name' : greeting,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              Text('What do you feel like today?', style: Theme.of(context).textTheme.headlineSmall),
            ],
          ),
        ),
        if (themeViewModel != null)
          SqCircleButton(
            glyph: themeViewModel.isDarkMode ? '☀️' : '🌙',
            tooltip: themeViewModel.isDarkMode ? 'Light mode' : 'Dark mode',
            onTap: () => themeViewModel.setDarkMode(!themeViewModel.isDarkMode),
          ),
      ],
    );
  }
}

class _TimeAndScopeFilters extends StatelessWidget {
  final QuestViewModel questViewModel;
  final ProfileViewModel profileViewModel;

  const _TimeAndScopeFilters({
    super.key,
    required this.questViewModel,
    required this.profileViewModel,
  });

  static const _scopes = [
    ('all', '🌐 All', AppColors.primary),
    ('gps', '📍 Nearby', AppColors.secondary),
    ('anywhere', '🏠 Anywhere', AppColors.secondary),
  ];

  void _reload() => questViewModel.loadRecommendations(profileViewModel.preferences);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SqSectionLabel(
          'I HAVE...',
          fontSize: 11,
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .55),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 40,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: kAvailableMinuteOptions.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final minutes = kAvailableMinuteOptions[index];
              return SqChoiceChip(
                label: '$minutes min',
                selected: questViewModel.selectedMinutes == minutes,
                onSelected: (_) {
                  questViewModel.setMinutes(minutes);
                  _reload();
                },
              );
            },
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            for (final (value, label, color) in _scopes)
              SqChoiceChip(
                label: label,
                selected: questViewModel.selectedLocationScope == value,
                selectedColor: color,
                onSelected: (_) {
                  questViewModel.setLocationScope(value);
                  _reload();
                },
              ),
          ],
        ),
      ],
    );
  }
}

/// "Social vibe for this session" (BQ5): overrides the profile's social level
/// for this session only and reloads recommend_quests. Starts on the
/// profile's value so the user sees what they're changing from.
class _SocialMoodFilter extends StatelessWidget {
  final QuestViewModel questViewModel;
  final ProfileViewModel profileViewModel;

  const _SocialMoodFilter({
    super.key,
    required this.questViewModel,
    required this.profileViewModel,
  });

  static const _levels = [
    ('solo', '🙋', 'Just me'),
    ('social', '👫', 'With someone'),
    ('group', '👥', 'In a group'),
  ];

  /// A level's chip text without its emoji, for sentences that mention it.
  static String nameOf(String level) => _levels.firstWhere((entry) => entry.$1 == level).$3;

  @override
  Widget build(BuildContext context) {
    final current = questViewModel.effectiveSocialLevel(profileViewModel.preferences);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Social vibe for this session', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            for (final (value, emoji, name) in _levels)
              SqChoiceChip(
                label: '$emoji $name',
                selected: current == value,
                onSelected: (_) {
                  questViewModel.setSessionSocialLevel(value);
                  questViewModel.loadRecommendations(profileViewModel.preferences);
                },
              ),
          ],
        ),
      ],
    );
  }
}

/// Kotlin's "YOUR ACTIVE QUEST" card: teal tint, progress bar, tap to go on.
class _ContinueBanner extends StatelessWidget {
  final String userQuestId;

  const _ContinueBanner({super.key, required this.userQuestId});

  @override
  Widget build(BuildContext context) {
    final questViewModel = context.watch<QuestViewModel>();
    final quest = questViewModel.questById(userQuestId);
    final mission = questViewModel.currentMission;
    if (quest == null || mission == null) return const SizedBox.shrink();
    final total = questViewModel.stepsOf(quest.id).length;
    final done = mission.completedSteps.length;
    final faded = Theme.of(context).colorScheme.onSurface.withValues(alpha: .62);

    return SqTintCard(
      color: AppColors.secondary.withValues(alpha: .14),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const MissionTabView(isTab: false)),
      ),
      child: Row(
        children: [
          Text(quest.emoji ?? '🎯', style: const TextStyle(fontSize: 30)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SqSectionLabel('YOUR ACTIVE QUEST', color: AppColors.secondary),
                const SizedBox(height: 4),
                Text(quest.title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                if (quest.isSponsored) ...[const SizedBox(height: 4), const SponsoredBadge()],
                const SizedBox(height: 4),
                SqProgressBar(value: total == 0 ? 0 : done / total, height: 5),
                const SizedBox(height: 4),
                Text(
                  total == 0 ? 'Tap to continue' : '$done of $total steps · tap to continue',
                  style: TextStyle(fontSize: 11, color: faded),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Kotlin's "LIVE CONTEXT" card: time of day, weather and location from the
/// last context snapshot, with "Enable location" or "Refresh context".
class _LiveContextCard extends StatelessWidget {
  final QuestViewModel questViewModel;

  const _LiveContextCard({super.key, required this.questViewModel});

  static String _timeLabel(String timeOfDay) => switch (timeOfDay) {
    'morning' => 'Morning',
    'afternoon' => 'Afternoon',
    'evening' => 'Evening',
    'night' => 'Night',
    _ => timeOfDay,
  };

  static String _weatherLabel(AppContext appContext) {
    final code = appContext.weatherCode;
    if (code == null) return 'Weather unavailable';
    if (appContext.isRainy) return 'Rainy';
    if (code <= 1) return 'Clear';
    if (code <= 3) return 'Cloudy';
    if (code == 45 || code == 48) return 'Foggy';
    if ((code >= 71 && code <= 77) || code == 85 || code == 86) return 'Snowy';
    return 'Mixed weather';
  }

  /// Reads the position (asking for permission when needed), then reloads
  /// the suggestions with the new context so Explore follows it.
  Future<void> _enableLocation(BuildContext context) async {
    final profileViewModel = context.read<ProfileViewModel>();
    final messenger = ScaffoldMessenger.of(context);
    await questViewModel.requestUserLocation();
    if (questViewModel.userLocationUnavailable) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Could not get your location. Check that location is on and Sidequests has permission.'),
        ),
      );
      return;
    }
    await questViewModel.loadRecommendations(profileViewModel.preferences);
  }

  @override
  Widget build(BuildContext context) {
    final appContext = questViewModel.currentContext;
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final hasLocation = questViewModel.userLatitude != null || (appContext?.hasLocation ?? false);
    final scopeLabel = switch (questViewModel.selectedLocationScope) {
      'gps' => 'Nearby',
      'anywhere' => 'Anywhere',
      _ => 'All',
    };

    return SqOutlinedCard(
      borderColor: Theme.of(context).colorScheme.outline.withValues(alpha: .35),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SqSectionLabel('LIVE CONTEXT', color: AppColors.secondary, letterSpacing: 1.1),
                    Text(
                      appContext == null
                          ? 'Updating context…'
                          : '${_timeLabel(appContext.timeOfDay)} • ${_weatherLabel(appContext)}',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                    ),
                    Text(
                      hasLocation ? '📍 Location available' : '📍 Location not available',
                      style: TextStyle(fontSize: 12, color: onSurface.withValues(alpha: .62)),
                    ),
                  ],
                ),
              ),
              Text(scopeLabel, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 8),
          if (!hasLocation) ...[
            Text(
              'Enable location to use Nearby quests. Anywhere works without GPS.',
              style: TextStyle(fontSize: 11, color: onSurface.withValues(alpha: .6)),
            ),
            const SizedBox(height: 8),
            SqTintCard(
              color: AppColors.secondary,
              radius: 12,
              padding: const EdgeInsets.symmetric(vertical: 15),
              onTap: questViewModel.isLocatingUser ? null : () => _enableLocation(context),
              child: Center(
                child: Text(
                  questViewModel.isLocatingUser ? 'Getting your location…' : 'Enable location',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12),
                ),
              ),
            ),
          ] else
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: questViewModel.refreshContext,
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 15),
                child: Center(
                  child: Text(
                    'Refresh context',
                    style: TextStyle(color: AppColors.secondary, fontWeight: FontWeight.w700, fontSize: 12),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Kotlin's "Discover more": shortcut cards into the extra screens (here,
/// Group challenges — it opens offline too, showing the saved challenges)
/// and the shake hint.
class _DiscoverMoreSection extends StatelessWidget {
  const _DiscoverMoreSection({super.key});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Discover more', style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _DiscoverShortcut(
                emoji: '👥',
                title: 'Group challenges',
                subtitle: 'Explore together',
                onTap: () => Navigator.of(context).push(GroupChallengesView.route()),
              ),
            ),
            const SizedBox(width: 10),
            const Expanded(child: SizedBox()),
          ],
        ),
        const SizedBox(height: 8),
        Text('Shake your phone for a surprise quest.', style: textTheme.bodySmall),
      ],
    );
  }
}

class _DiscoverShortcut extends StatelessWidget {
  final String emoji;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _DiscoverShortcut({required this.emoji, required this.title, required this.subtitle, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return SqTintCard(
      color: scheme.primaryContainer,
      radius: 18,
      padding: const EdgeInsets.all(14),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(emoji, style: textTheme.headlineSmall),
          const SizedBox(height: 6),
          Text(
            title,
            style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700, color: scheme.onPrimaryContainer),
          ),
          const SizedBox(height: 6),
          Text(subtitle, style: textTheme.bodySmall?.copyWith(color: scheme.onPrimaryContainer)),
        ],
      ),
    );
  }
}

/// Explains why [QuestViewModel.filteredCatalog] just reordered itself:
/// rain or nighttime pushes 'anywhere' quests first. Rain takes priority
/// over night in the message when both apply. A plain card, as in Kotlin.
class _ContextAdaptationBanner extends StatelessWidget {
  final AppContext appContext;

  const _ContextAdaptationBanner({super.key, required this.appContext});

  @override
  Widget build(BuildContext context) {
    final String message;
    if (appContext.isRainy) {
      final age = appContext.weatherAge;
      message = age != null
          ? 'Based on the last known weather (${age.inMinutes} min ago): showing indoor quests first.'
          : "It's raining: showing indoor quests first.";
    } else {
      message = "It's nighttime: prioritizing quests nearby or at home.";
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: SizedBox(
          width: double.infinity,
          child: Text(message, style: Theme.of(context).textTheme.bodyMedium),
        ),
      ),
    );
  }
}

class _RecommendedSection extends StatelessWidget {
  final QuestViewModel questViewModel;
  final ProfileViewModel profileViewModel;

  const _RecommendedSection({super.key, required this.questViewModel, required this.profileViewModel});

  @override
  Widget build(BuildContext context) {
    final isLoading = questViewModel.isLoadingRecommendations && questViewModel.recommendations.isEmpty;
    final likelihoodByCategory = questViewModel.completionLikelihoodByCategory;
    final awaitingLevel = questViewModel.socialLevelAwaitingReconnect;
    final isOffline = watchIsOffline(context);
    final recommendations = questViewModel.recommendations;
    final white78 = Colors.white.withValues(alpha: .78);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Kotlin's indigo "SMART PICKS FOR YOU" header card.
        SqTintCard(
          color: AppColors.primary,
          radius: 24,
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SqSectionLabel('SMART PICKS FOR YOU', color: AppColors.amber, letterSpacing: 1.1),
              const SizedBox(height: 4),
              Text(
                'Matched to your time, budget and vibe',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(color: Colors.white),
              ),
              const SizedBox(height: 8),
              Text(
                isLoading ? 'Refreshing recommendations…' : 'Based on your time, interests and history',
                style: TextStyle(color: white78, fontSize: 11, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
        if (questViewModel.completionLabelsFromCache && recommendations.isNotEmpty) const _SavedDataNote(),
        if (questViewModel.recommendationsFromCache) ...[
          const SizedBox(height: 8),
          SqMetaPill('Saved recommendations', color: Theme.of(context).colorScheme.primaryContainer),
        ],
        if (awaitingLevel != null) ...[
          const SizedBox(height: 8),
          OfflineNotice(
            message: OfflineMessages.awaitingSocialLevel(_SocialMoodFilter.nameOf(awaitingLevel)),
          ),
        ],
        if (isOffline && recommendations.isNotEmpty) ...[
          const SizedBox(height: 8),
          const OfflineNotice(message: OfflineMessages.browseMissions),
        ],
        if (isLoading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          ),
        for (final recommendation in recommendations)
          if (questViewModel.questById(recommendation.questId) case final quest?)
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: _RecommendationCard(
                quest: quest,
                isOffline: isOffline,
                recommendation: recommendation,
                completionLevel: questViewModel.completionLevelFor(quest, likelihoodByCategory),
                progressLabel: _ExploreViewState._progressLabel(questViewModel, quest),
                onDismiss: () => questViewModel.skipRecommendation(quest.id, profileViewModel.preferences),
                onTap: () {
                  questViewModel.registerInteraction();
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => QuestDetailView(quest: quest, wasRecommended: true),
                    ),
                  );
                },
              ),
            ),
        const SizedBox(height: 14),
      ],
    );
  }
}

class _RecommendationCard extends StatefulWidget {
  final Quest quest;

  /// "Start now" needs the internet: offline it's shown disabled, saying so.
  final bool isOffline;
  final QuestRecommendation recommendation;
  final CompletionLevel completionLevel;
  final String? progressLabel;
  final VoidCallback onDismiss;
  final VoidCallback onTap;

  const _RecommendationCard({
    required this.quest,
    this.isOffline = false,
    required this.recommendation,
    required this.completionLevel,
    this.progressLabel,
    required this.onDismiss,
    required this.onTap,
  });

  @override
  State<_RecommendationCard> createState() => _RecommendationCardState();
}

class _RecommendationCardState extends State<_RecommendationCard> {
  bool _isStartingInstantPlan = false;

  /// "Start now" (BQ4's 'instant_plan' start path): skips QuestDetailView
  /// and goes straight to the mission checklist.
  ///
  /// Accepting the quest flips `currentMission` from null to non-null, which
  /// inserts the "continue" banner above this card's section. `navigator`
  /// and `messenger` are captured up front and used unconditionally: they're
  /// the app's long-lived Navigator/ScaffoldMessenger, not tied to this
  /// (possibly-by-then-disposed) State. Only the `setState` calls need the
  /// `mounted` guard.
  Future<void> _startInstantPlan() async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final questViewModel = context.read<QuestViewModel>();
    if (mounted) setState(() => _isStartingInstantPlan = true);
    final started = await questViewModel.startInstantPlan(widget.quest);
    if (mounted) setState(() => _isStartingInstantPlan = false);
    if (!started) {
      // Not started (no connection, or it didn't answer): stay on Explore.
      messenger.showSnackBar(
        SnackBar(content: Text(questViewModel.errorMessage ?? 'Could not start the quest.')),
      );
      return;
    }
    navigator.push(MaterialPageRoute(builder: (_) => const MissionTabView(isTab: false)));
  }

  @override
  Widget build(BuildContext context) {
    final quest = widget.quest;
    final recommendation = widget.recommendation;
    final reasons = <String>[
      if (recommendation.timeMatch) 'Fits your time',
      if (recommendation.interestMatch) 'Matches your interests',
      if (recommendation.locationMatch) 'Near you',
      if (recommendation.socialMatch) 'Great for you',
    ];

    return SqQuestCard(
      onTap: widget.onTap,
      emoji: quest.emoji ?? '🎯',
      title: quest.title,
      category: categoryLabelEs(quest.category),
      description: quest.description,
      tags: questTags(quest, progressLabel: widget.progressLabel),
      completion: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          CompletionLikelihoodLabel(level: widget.completionLevel),
          for (final reason in reasons) SqMetaPill(reason, color: AppColors.secondary.withValues(alpha: .16)),
        ],
      ),
      meta: questMeta(quest, distanceKm: context.read<QuestViewModel>().distanceKmTo(quest)),
      actions: [
        TextButton(
          onPressed: _isStartingInstantPlan ? null : widget.onDismiss,
          child: const Text('Not for me'),
        ),
        if (widget.isOffline)
          FilledButton.icon(
            onPressed: null,
            style: sqPillButtonStyle(),
            icon: const Icon(Icons.wifi_off, size: 16),
            label: const Text('Offline'),
          )
        else
          FilledButton(
            onPressed: _isStartingInstantPlan ? null : _startInstantPlan,
            style: sqPillButtonStyle(),
            child: _isStartingInstantPlan
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Text('Start now →'),
          ),
      ],
    );
  }
}

/// Kotlin QuestCard's top pills: NEW, SPONSORED, GROUP and the open attempt.
List<Widget> questTags(Quest quest, {String? progressLabel}) => [
  if (quest.isNew) SqMetaPill('NEW', color: AppColors.amber.withValues(alpha: .2)),
  if (quest.isSponsored) const SponsoredBadge(),
  if (quest.isGroup) SqMetaPill('GROUP', color: AppColors.primary.withValues(alpha: .16)),
  if (progressLabel != null) SqMetaPill('⚡ $progressLabel', color: AppColors.secondary.withValues(alpha: .22)),
];

/// Kotlin QuestCard's ⏱ 💰 📍 pills; the 📍 one says how far the quest is
/// once the user's position is known ([distanceKm]).
List<String> questMeta(Quest quest, {double? distanceKm}) => [
  '⏱ ${quest.durationMinutes} min',
  '💰 ${quest.estimatedCost > 0 ? '\$${quest.estimatedCost.toStringAsFixed(0)}' : 'Free'}',
  if (quest.locationMode == 'anywhere')
    '🏠 Anywhere'
  else if (distanceKm != null)
    '📍 ${formatDistanceKm(distanceKm)}'
  else
    '📍 ${quest.locationName ?? 'Nearby'}',
];

/// 0.35 -> "350 m", 1.234 -> "1.2 km".
String formatDistanceKm(double km) =>
    km < 1 ? '${(km * 1000).round()} m' : '${km.toStringAsFixed(1)} km';

/// "EXPLORE BY CATEGORY" down to its rows: category chips and the
/// loading/error/empty/offline states. The rows themselves are built by
/// [_ExploreViewState.build], lazily.
class _AllMissionsHeader extends StatelessWidget {
  final QuestViewModel questViewModel;

  /// [QuestViewModel.filteredCatalog], read once by the caller.
  final List<Quest> missions;

  const _AllMissionsHeader({required this.questViewModel, required this.missions});

  @override
  Widget build(BuildContext context) {
    if (questViewModel.isLoading && questViewModel.catalog.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (questViewModel.errorMessage != null && questViewModel.catalog.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(child: Text(questViewModel.errorMessage!)),
      );
    }

    final categoryOptions = [null, 'sponsored', ...questViewModel.categories];

    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SqSectionLabel(
            'EXPLORE BY CATEGORY',
            fontSize: 11,
            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .55),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 40,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: categoryOptions.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final value = categoryOptions[index];
                final label = value == null
                    ? 'All'
                    : value == 'sponsored'
                    ? '⭐ Sponsored'
                    : categoryLabelEs(value);
                return SqChoiceChip(
                  label: label,
                  selected: questViewModel.selectedCategory == value,
                  selectedColor: value == null ? AppColors.primary : AppColors.secondary,
                  onSelected: (_) => questViewModel.setCategory(value),
                );
              },
            ),
          ),
          if (questViewModel.completionLabelsFromCache && missions.isNotEmpty) const _SavedDataNote(),
          if (questViewModel.catalogUnavailable)
            const Padding(
              padding: EdgeInsets.only(top: 14),
              child: Text(
                'Offline and no quests saved on the phone. '
                'Connect and pull down to load them.',
              ),
            )
          else if (missions.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 14),
              child: Text('No quests match these filters.'),
            ),
        ],
      ),
    );
  }
}

/// Next to the "chance you'll finish it" labels when they were computed
/// from data saved on the device.
class _SavedDataNote extends StatelessWidget {
  const _SavedDataNote();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(
        'Based on your saved data',
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    );
  }
}

/// A catalogue row: Kotlin's QuestCard without action buttons.
class _QuestRow extends StatelessWidget {
  final Quest quest;
  final double? distanceKm;
  final CompletionLevel completionLevel;
  final String? progressLabel;
  final VoidCallback onTap;

  const _QuestRow({
    required this.quest,
    this.distanceKm,
    required this.completionLevel,
    this.progressLabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (!kReleaseMode) ExploreBuildStats.questRowBuilds++;
    return SqQuestCard(
      onTap: onTap,
      emoji: quest.emoji ?? '🎯',
      title: quest.title,
      category: categoryLabelEs(quest.category),
      description: quest.description,
      tags: questTags(quest, progressLabel: progressLabel),
      completion: CompletionLikelihoodLabel(level: completionLevel),
      meta: questMeta(quest, distanceKm: distanceKm),
    );
  }
}
