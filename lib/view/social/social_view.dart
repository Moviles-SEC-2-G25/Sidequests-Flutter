import 'package:flutter/material.dart';

import '../../core/app_theme.dart';

/// "Social" tab: friends' shared mission photos, per the Figma reference.
///
/// Sidequests-Backend has no `friends`/`group_challenges` tables and
/// Realtime is not enabled (confirmed against every migration in
/// supabase/migrations/), so there is no real social graph or shared-photo
/// data to show. Rather than hardcode fake friends/photos to look
/// functional, this renders the real, honest empty state — the screen slot
/// and visual language match the design; the content does not pretend to
/// be backed by data that doesn't exist yet.
class SocialView extends StatelessWidget {
  const SocialView({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          children: [
            Text(
              'FRIENDS ONLY',
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(color: AppColors.primary, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text('Quest photos', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 6),
            Text(
              'What your friends are up to',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 32),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                children: [
                  const Icon(Icons.people_outline, size: 40, color: AppColors.primary),
                  const SizedBox(height: 12),
                  Text(
                    'The social feed is not available yet',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'It needs friends and shared photos, and the shared '
                    'backend does not have those tables or Realtime '
                    'enabled yet.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
