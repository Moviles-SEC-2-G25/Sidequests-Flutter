import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../analytics/analytics_tracker.dart';
import '../data/services/shake_detector.dart';
import '../viewmodel/context/context_status_view_model.dart';
import '../viewmodel/profile/profile_view_model.dart';
import '../viewmodel/quests/quest_view_model.dart';
import 'widgets/context_banner.dart';

import 'profile/profile_view.dart';
import 'quests/explore_view.dart';
import 'quests/mission_tab_view.dart';
import 'quests/nearby_view.dart';
import 'quests/quest_completed_view.dart';
import 'quests/quest_detail_view.dart';
import 'social/social_view.dart';

/// Bottom-navigation shell: Explorar, Cerca, Social, Misión, Perfil — the
/// five tabs shown in the Figma reference. The per-domain ViewModels these
/// tabs read are provided above MaterialApp's Navigator (see app.dart), not
/// here, so screens pushed on top of a tab (e.g. quest detail) can still
/// read them.
class HomeShell extends StatefulWidget {
  /// Null: the device's accelerometer.
  final ShakeDetector? shakeDetector;

  const HomeShell({super.key, this.shakeDetector});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  static const _exploreTabIndex = 0;

  int _index = 0;
  late final ShakeDetector _shakeDetector = widget.shakeDetector ?? ShakeDetector();
  StreamSubscription<void>? _shakeSubscription;

  /// Kept here because this State's context is above its provider (see
  /// build), so it can't read it from there; the provider still disposes it.
  ContextStatusViewModel? _contextStatus;

  /// No other screen on top of this one.
  bool _isRouteCurrent = true;
  bool _isAppResumed = true;
  late final StreamSubscription<CheckInEvent> _checkInSubscription;
  late final StreamSubscription<void> _exploreTabSubscription;
  late final AppLifecycleListener _lifecycleListener;

  static const _pages = [
    ExploreView(),
    NearbyView(),
    SocialView(),
    MissionTabView(),
    ProfileView(),
  ];

  @override
  void initState() {
    super.initState();
    _updateShakeSubscription();

    final questViewModel = context.read<QuestViewModel>();
    // Lives here, not in MissionTabView: the shell is mounted exactly once
    // (MissionTabView can also be pushed on top of itself), and the
    // check-in should be announced whichever tab is showing.
    _checkInSubscription = questViewModel.checkInEvents.listen(_onCheckIn);
    _exploreTabSubscription = questViewModel.exploreTabRequests.listen(
      (_) => _selectTab(_exploreTabIndex),
    );
    // The location check-in's GPS only runs in the foreground.
    _lifecycleListener = AppLifecycleListener(
      onStateChange: (state) {
        questViewModel.setForeground(
          state == AppLifecycleState.resumed || state == AppLifecycleState.inactive,
        );
        _isAppResumed = state == AppLifecycleState.resumed;
        _updateShakeSubscription();
      },
    );
  }

  /// Runs when another screen is pushed on top of this one or popped off it.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final isCurrent = ModalRoute.isCurrentOf(context) ?? true;
    if (isCurrent == _isRouteCurrent) return;
    _isRouteCurrent = isCurrent;
    _updateShakeSubscription();
    if (isCurrent && _index == _exploreTabIndex) {
      context.read<QuestViewModel>().onExploreVisible();
    }
  }

  /// Back online, and the connection held (ContextStatusViewModel waits it
  /// out): reloads what the offline banner said couldn't load. load() first
  /// syncs the queued quest writes, then retries pending photo uploads;
  /// analytics queued offline go out too.
  Future<void> _refreshAfterReconnect() async {
    if (!mounted) return;
    final questViewModel = context.read<QuestViewModel>();
    final profileViewModel = context.read<ProfileViewModel>();
    unawaited(context.read<AnalyticsTracker>().flushPending());
    try {
      await questViewModel.refreshAfterReconnect(profileViewModel.preferences);
    } catch (_) {
      // Dropped again mid-reload: the cached data stays and the next
      // reconnection tries again.
    }
  }

  void _selectTab(int index) {
    if (!mounted) return;
    setState(() {
      _index = index;
      _updateShakeSubscription();
      if (index == _exploreTabIndex) context.read<QuestViewModel>().onExploreVisible();
    });
  }

  void _onCheckIn(CheckInEvent event) {
    if (!mounted) return;
    final navigator = Navigator.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          event.completedQuest
              ? '📍 ¡Llegaste! Misión completada por ubicación.'
              : '📍 ¡Llegaste! Paso verificado por ubicación.',
        ),
        // No forced navigation — the user may be on another tab.
        action: event.completedQuest
            ? SnackBarAction(
                label: 'Calificar',
                onPressed: () => navigator.push(
                  MaterialPageRoute(
                    builder: (_) => QuestCompletedView(mission: event.mission, quest: event.quest),
                  ),
                ),
              )
            : null,
      ),
    );
  }

  /// "Shake to decide" only fires while Explorar (IndexedStack index 0) is
  /// the visible tab — IndexedStack keeps every page mounted, so this can't
  /// rely on ExploreView's own lifecycle and must gate on `_index` instead —
  /// with no other screen on top and the app in the foreground. Cancelling
  /// also turns the sensor off.
  void _updateShakeSubscription() {
    final shouldListen = _index == _exploreTabIndex && _isRouteCurrent && _isAppResumed;
    final isListening = _shakeSubscription != null;
    if (shouldListen == isListening) return;
    if (shouldListen) {
      _shakeSubscription = _shakeDetector.onShake.listen((_) => _onShake());
    } else {
      _shakeSubscription?.cancel();
      _shakeSubscription = null;
    }
  }

  void _onShake() {
    // A shake right after a push, before the route change reaches this State.
    if (!(ModalRoute.isCurrentOf(context) ?? true)) return;
    final questViewModel = context.read<QuestViewModel>();
    final isOffline = _contextStatus?.isOffline ?? false;
    final candidates = questViewModel.shakeCandidates(isOffline: isOffline);
    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            questViewModel.shakeHasNoSavedCatalog(isOffline: isOffline)
                ? 'Sin conexión y sin misiones guardadas: conéctate una vez para usar la misión sorpresa'
                : 'No hay misiones disponibles para sorprenderte ahora.',
          ),
        ),
      );
      return;
    }

    final quest = candidates[Random().nextInt(candidates.length)];
    HapticFeedback.mediumImpact();
    questViewModel.trackShakeSurprise(quest.id);
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => QuestDetailView(quest: quest)));
  }

  @override
  void dispose() {
    _shakeSubscription?.cancel();
    _shakeDetector.dispose();
    _checkInSubscription.cancel();
    _exploreTabSubscription.cancel();
    _lifecycleListener.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => _contextStatus = ContextStatusViewModel(onReconnected: _refreshAfterReconnect),
      child: Scaffold(
      body: Column(
        children: [
          const ContextBanner(),
          Expanded(child: IndexedStack(index: _index, children: _pages)),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: _selectTab,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.explore_outlined), label: 'Explorar'),
          NavigationDestination(icon: Icon(Icons.location_on_outlined), label: 'Cerca'),
          NavigationDestination(icon: Icon(Icons.people_outline), label: 'Social'),
          NavigationDestination(icon: Icon(Icons.bolt_outlined), label: 'Misión'),
          NavigationDestination(icon: Icon(Icons.person_outline), label: 'Perfil'),
        ],
      ),
    ));
  }
}
