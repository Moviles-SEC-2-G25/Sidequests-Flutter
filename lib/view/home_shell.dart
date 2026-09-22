import 'package:flutter/material.dart';

import 'profile/profile_view.dart';
import 'quests/explore_view.dart';
import 'quests/mission_tab_view.dart';
import 'quests/nearby_view.dart';
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
  int _index = 0;

  static const _pages = [
    ExploreView(),
    NearbyView(),
    SocialView(),
    MissionTabView(),
    ProfileView(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: _pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (index) => setState(() => _index = index),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.explore_outlined), label: 'Explorar'),
          NavigationDestination(icon: Icon(Icons.location_on_outlined), label: 'Cerca'),
          NavigationDestination(icon: Icon(Icons.people_outline), label: 'Social'),
          NavigationDestination(icon: Icon(Icons.bolt_outlined), label: 'Misión'),
          NavigationDestination(icon: Icon(Icons.person_outline), label: 'Perfil'),
        ],
      ),
    );
  }
}
