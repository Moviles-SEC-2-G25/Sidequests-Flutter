import 'package:flutter/material.dart';

import 'group_challenges_view.dart';

/// "Social" tab, as in the Kotlin app's SocialScreen: the "Quest photos"
/// heading, an honest empty state for the feed, and the way into Group
/// Challenges.
///
/// Sidequests-Backend has no friends/shared-photos tables and Realtime is
/// not enabled, so there is no social feed to show; rather than fake friends
/// or photos, the screen says so and points to what does exist.
class SocialView extends StatelessWidget {
  const SocialView({super.key});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          children: [
            Text('Quest photos', style: textTheme.headlineSmall),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  children: [
                    Text(
                      'The social feed is not available yet',
                      textAlign: TextAlign.center,
                      style: textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'You can still take on a quest together in Group Challenges.',
                      textAlign: TextAlign.center,
                      style: textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.of(context).push(GroupChallengesView.route()),
              child: const Text('Group Challenges'),
            ),
          ],
        ),
      ),
    );
  }
}
