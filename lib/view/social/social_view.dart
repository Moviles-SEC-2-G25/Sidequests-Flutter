import 'package:flutter/material.dart';

/// Social feed / friends / group challenges. The backend has no
/// friends/group-challenge tables or Realtime channel yet (see
/// SocialRepository), so this view only establishes the slot in the
/// View -> ViewModel -> Repository chain.
class SocialView extends StatelessWidget {
  const SocialView({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Social')),
      body: const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Friends and group challenges are coming soon.',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
