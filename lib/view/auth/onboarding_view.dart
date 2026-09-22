import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../analytics/onboarding_step.dart';
import '../../data/local/local_data_source.dart';
import '../../models/user_preferences.dart';
import '../../viewmodel/auth/auth_view_model.dart';
import '../../viewmodel/profile/profile_view_model.dart';

/// One-time onboarding shown right after sign-up: a welcome screen, then
/// preference setup. Each screen is a step in the BQ3 funnel — the
/// `onboarding_step_completed` event for a step fires only when the user
/// advances past it (tapping its button), never when the screen is entered.
class OnboardingView extends StatefulWidget {
  final VoidCallback onFinished;

  const OnboardingView({super.key, required this.onFinished});

  @override
  State<OnboardingView> createState() => _OnboardingViewState();
}

class _OnboardingViewState extends State<OnboardingView> {
  static const _difficulties = ['easy', 'medium', 'hard'];
  static const _socialLevels = ['solo', 'social', 'group'];
  static const _locationModes = ['all', 'gps', 'anywhere'];

  bool _onWelcomeStep = true;
  UserPreferences _preferences = const UserPreferences();
  bool _isSaving = false;

  void _advancePastWelcome() {
    context.read<AuthViewModel>().trackOnboardingStep(OnboardingStep.welcome);
    setState(() => _onWelcomeStep = false);
  }

  Future<void> _advancePastPreferences() async {
    setState(() => _isSaving = true);
    final saved = await context
        .read<ProfileViewModel>()
        .updatePreferences(_preferences);
    if (!mounted) return;
    if (saved) {
      context.read<AuthViewModel>().trackOnboardingStep(OnboardingStep.preferences);
      await context.read<LocalDataSource>().setCompletedOnboarding(true);
      widget.onFinished();
    } else {
      setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_onWelcomeStep ? 'Welcome' : 'Set up your preferences')),
      body: _onWelcomeStep ? _buildWelcomeStep(context) : _buildPreferencesStep(context),
    );
  }

  Widget _buildWelcomeStep(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Welcome to Sidequests!', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 12),
            const Text(
              'Bite-sized real-world quests, matched to your time, budget and mood.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton(onPressed: _advancePastWelcome, child: const Text('Get started')),
          ],
        ),
      ),
    );
  }

  Widget _buildPreferencesStep(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('Preferred difficulty', style: Theme.of(context).textTheme.titleMedium),
        Wrap(
          spacing: 8,
          children: _difficulties
              .map(
                (value) => ChoiceChip(
                  label: Text(value),
                  selected: _preferences.preferredDifficulty == value,
                  onSelected: (_) => setState(
                    () => _preferences = _preferences.copyWith(preferredDifficulty: value),
                  ),
                ),
              )
              .toList(),
        ),
        const SizedBox(height: 24),
        Text('Social level', style: Theme.of(context).textTheme.titleMedium),
        Wrap(
          spacing: 8,
          children: _socialLevels
              .map(
                (value) => ChoiceChip(
                  label: Text(value),
                  selected: _preferences.socialLevel == value,
                  onSelected: (_) => setState(
                    () => _preferences = _preferences.copyWith(socialLevel: value),
                  ),
                ),
              )
              .toList(),
        ),
        const SizedBox(height: 24),
        Text('Location mode', style: Theme.of(context).textTheme.titleMedium),
        Wrap(
          spacing: 8,
          children: _locationModes
              .map(
                (value) => ChoiceChip(
                  label: Text(value),
                  selected: _preferences.locationMode == value,
                  onSelected: (_) => setState(
                    () => _preferences = _preferences.copyWith(locationMode: value),
                  ),
                ),
              )
              .toList(),
        ),
        const SizedBox(height: 24),
        Text(
          'Typical available time: ${_preferences.typicalTimeMinutes} min',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        Slider(
          min: 5,
          max: 240,
          divisions: 47,
          value: _preferences.typicalTimeMinutes.toDouble(),
          onChanged: (value) => setState(
            () => _preferences = _preferences.copyWith(
              typicalTimeMinutes: value.round(),
            ),
          ),
        ),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _isSaving ? null : _advancePastPreferences,
          child: _isSaving
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Continue'),
        ),
      ],
    );
  }
}
