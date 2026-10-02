import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../data/services/shake_detector.dart';
import '../viewmodel/context/context_status_view_model.dart';
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
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  static const _exploreTabIndex = 0;

  int _index = 0;
  final ShakeDetector _shakeDetector = ShakeDetector();
  StreamSubscription<void>? _shakeSubscription;
  late final StreamSubscription<CheckInEvent> _checkInSubscription;
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
    // The location check-in's GPS only runs in the foreground.
    _lifecycleListener = AppLifecycleListener(
      onStateChange: (state) => questViewModel.setForeground(
        state == AppLifecycleState.resumed || state == AppLifecycleState.inactive,
      ),
    );
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
  /// rely on ExploreView's own lifecycle and must gate on `_index` instead.
  void _updateShakeSubscription() {
    final shouldListen = _index == _exploreTabIndex;
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
    final questViewModel = context.read<QuestViewModel>();
    final candidates = questViewModel.shakeCandidates;
    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No hay misiones disponibles para sorprenderte ahora.')),
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
    _lifecycleListener.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => ContextStatusViewModel(),
      child: Scaffold(
      body: Column(
        children: [
          const ContextBanner(),
          Expanded(child: IndexedStack(index: _index, children: _pages)),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (index) => setState(() {
          _index = index;
          _updateShakeSubscription();
        }),
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
