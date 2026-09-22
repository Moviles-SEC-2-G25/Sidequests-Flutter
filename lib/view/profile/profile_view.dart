import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../viewmodel/auth/auth_view_model.dart';
import '../../viewmodel/profile/profile_view_model.dart';

class ProfileView extends StatefulWidget {
  const ProfileView({super.key});

  @override
  State<ProfileView> createState() => _ProfileViewState();
}

class _ProfileViewState extends State<ProfileView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => context.read<ProfileViewModel>().load(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final profileViewModel = context.watch<ProfileViewModel>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () => context.read<AuthViewModel>().signOut(),
          ),
        ],
      ),
      body: profileViewModel.isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  profileViewModel.profile?.displayName ?? 'Adventurer',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 16),
                ListTile(
                  title: const Text('Preferred difficulty'),
                  trailing: Text(profileViewModel.preferences.preferredDifficulty),
                ),
                ListTile(
                  title: const Text('Social level'),
                  trailing: Text(profileViewModel.preferences.socialLevel),
                ),
                ListTile(
                  title: const Text('Typical time'),
                  trailing: Text('${profileViewModel.preferences.typicalTimeMinutes} min'),
                ),
                ListTile(
                  title: const Text('Budget'),
                  trailing: Text('\$${profileViewModel.preferences.budgetMax}'),
                ),
              ],
            ),
    );
  }
}
