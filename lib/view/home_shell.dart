import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../analytics/analytics_tracker.dart';
import '../data/context/context_manager.dart';
import '../repository/profile_repository.dart';
import '../repository/quest_repository.dart';
import '../repository/social_repository.dart';
import '../viewmodel/auth/auth_view_model.dart';
import '../viewmodel/profile/profile_view_model.dart';
import '../viewmodel/quests/quest_view_model.dart';
import '../viewmodel/social/social_view_model.dart';
import 'profile/profile_view.dart';
import 'quests/quest_list_view.dart';
import 'social/social_view.dart';

/// Bottom-navigation shell across the Quest, Social and Profile view groups.
/// Only reachable once [AuthViewModel] has a signed-in user, so this is
/// where the per-domain ViewModels that need a `userId` get wired.
class HomeShell extends StatelessWidget {
  const HomeShell({super.key});

  @override
  Widget build(BuildContext context) {
    final userId = context.read<AuthViewModel>().userId!;

    return MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (context) => QuestViewModel(
            context.read<QuestRepository>(),
            context.read<ContextManager>(),
            context.read<AnalyticsTracker>(),
            userId,
          ),
        ),
        ChangeNotifierProvider(
          create: (context) => ProfileViewModel(context.read<ProfileRepository>(), userId),
        ),
        ChangeNotifierProvider(
          create: (context) => SocialViewModel(context.read<SocialRepository>()),
        ),
      ],
      child: const _HomeShellBody(),
    );
  }
}

class _HomeShellBody extends StatefulWidget {
  const _HomeShellBody();

  @override
  State<_HomeShellBody> createState() => _HomeShellBodyState();
}

class _HomeShellBodyState extends State<_HomeShellBody> {
  int _index = 0;

  static const _pages = [QuestListView(), SocialView(), ProfileView()];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: _pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (index) => setState(() => _index = index),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.explore_outlined), label: 'Quests'),
          NavigationDestination(icon: Icon(Icons.people_outline), label: 'Social'),
          NavigationDestination(icon: Icon(Icons.person_outline), label: 'Profile'),
        ],
      ),
    );
  }
}
