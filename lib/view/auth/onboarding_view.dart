import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../analytics/onboarding_step.dart';
import '../../core/app_theme.dart';
import '../../core/category_labels.dart';
import '../../data/local/local_data_source.dart';
import '../../models/user_preferences.dart';
import '../../viewmodel/auth/auth_view_model.dart';
import '../../viewmodel/profile/profile_view_model.dart';
import '../widgets/offline_notice.dart';
import '../widgets/sq_components.dart';

/// One-time onboarding shown right after sign-up, laid out like the Kotlin
/// app's OnboardingScreen: four short steps (interests, difficulty, time,
/// budget & social vibe) under a segmented progress bar.
///
/// Each part keeps its BQ3 funnel step: `onboarding_step_completed` for
/// [OnboardingStep.welcome] fires when the user advances past the first
/// screen, and [OnboardingStep.preferences] once the preferences are saved —
/// never when a screen is entered.
class OnboardingView extends StatefulWidget {
  final VoidCallback onFinished;

  const OnboardingView({super.key, required this.onFinished});

  @override
  State<OnboardingView> createState() => _OnboardingViewState();
}

class _OnboardingViewState extends State<OnboardingView> {
  static const _stepCount = 4;
  static const _timeOptions = [10, 20, 30, 45, 60];
  static const _budgetOptions = [0.0, 5.0, 15.0, 30.0];

  int _step = 0;
  bool _welcomeTracked = false;
  UserPreferences _preferences = const UserPreferences();
  bool _isSaving = false;

  void _trackWelcome() {
    if (_welcomeTracked) return;
    _welcomeTracked = true;
    context.read<AuthViewModel>().trackOnboardingStep(OnboardingStep.welcome);
  }

  void _next() {
    if (_step == 0) _trackWelcome();
    if (_step < _stepCount - 1) {
      setState(() => _step++);
    } else {
      _savePreferences();
    }
  }

  /// "Skip setup": saves what was picked so far (or the defaults) the same way.
  void _skip() {
    _trackWelcome();
    _savePreferences();
  }

  Future<void> _savePreferences() async {
    setState(() => _isSaving = true);
    final profileViewModel = context.read<ProfileViewModel>();
    final saved = await profileViewModel.updatePreferences(_preferences);
    if (!mounted) return;
    if (saved) {
      context.read<AuthViewModel>().trackOnboardingStep(OnboardingStep.preferences);
      await context.read<LocalDataSource>().setCompletedOnboarding(true);
      widget.onFinished();
    } else {
      // Not saved: stay on this step, saying why, so it can be tried again.
      setState(() => _isSaving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(profileViewModel.errorMessage ?? 'Could not save your preferences.'),
        ),
      );
    }
  }

  void _toggleInterest(String value) {
    final updated = List<String>.from(_preferences.interests);
    updated.contains(value) ? updated.remove(value) : updated.add(value);
    setState(() => _preferences = _preferences.copyWith(interests: updated));
  }

  @override
  Widget build(BuildContext context) {
    final isOffline = watchIsOffline(context);
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final (title, subtitle) = switch (_step) {
      0 => ('What do you love doing?', 'Pick as many as you like — or skip.'),
      1 => ('How adventurous are you feeling?', 'This shapes the challenge level of your quests.'),
      2 => ('How much time do you usually have?', "We'll match quests to your typical free slot."),
      _ => ('Budget & vibe?', 'Last one — promise.'),
    };
    final canSave = !_isSaving && !isOffline;

    return PopScope(
      canPop: _step == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _step > 0) setState(() => _step--);
      },
      child: Scaffold(
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        for (var index = 0; index < _stepCount; index++) ...[
                          if (index > 0) const SizedBox(width: 6),
                          Expanded(
                            child: SqProgressBar(
                              value: index <= _step ? 1 : 0,
                              height: 4,
                              color: AppColors.primary,
                              trackColor: scheme.outline,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 28),
                    SqSectionLabel(
                      'STEP ${_step + 1} OF $_stepCount',
                      color: scheme.primary,
                      fontSize: 11,
                      letterSpacing: 1.3,
                    ),
                    const SizedBox(height: 7),
                    Text(title, style: textTheme.headlineMedium),
                    const SizedBox(height: 7),
                    Text(
                      subtitle,
                      style: textTheme.bodyMedium?.copyWith(color: scheme.onSurface.withValues(alpha: .62)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 26),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: _stepBody(context),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (isOffline && _step == _stepCount - 1) ...[
                      const OfflineNotice(message: OfflineMessages.savePreferences),
                      const SizedBox(height: 10),
                    ],
                    FilledButton(
                      onPressed: _step < _stepCount - 1 ? (_isSaving ? null : _next) : (canSave ? _next : null),
                      child: _isSaving
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(_step < _stepCount - 1 ? 'Continue →' : 'Start Exploring →'),
                    ),
                    const SizedBox(height: 10),
                    InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: canSave ? _skip : null,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          "Skip setup — I'll explore freely",
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 12, color: scheme.onSurface.withValues(alpha: .5)),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _stepBody(BuildContext context) {
    switch (_step) {
      case 0:
        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final interest in kInterestOptions)
              SqChoiceChip(
                label: categoryLabelEs(interest),
                selected: _preferences.interests.contains(interest),
                onSelected: (_) => _toggleInterest(interest),
              ),
          ],
        );
      case 1:
        return Column(
          children: [
            for (final (emoji, value, description) in const [
              ('🌱', 'easy', 'Low-effort, zero planning, instant fun'),
              ('⚡', 'medium', 'A bit of effort, noticeably rewarding'),
              ('🔥', 'hard', 'Takes commitment — worth it every time'),
            ]) ...[
              _DifficultyOption(
                emoji: emoji,
                label: _capitalize(value),
                description: description,
                selected: _preferences.preferredDifficulty == value,
                onTap: () => setState(() => _preferences = _preferences.copyWith(preferredDifficulty: value)),
              ),
              const SizedBox(height: 12),
            ],
          ],
        );
      case 2:
        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final minutes in _timeOptions)
              SqChoiceChip(
                label: minutes == 60 ? '1 hr+' : '$minutes min',
                selected: _preferences.typicalTimeMinutes == minutes,
                selectedColor: AppColors.amber,
                onSelected: (_) =>
                    setState(() => _preferences = _preferences.copyWith(typicalTimeMinutes: minutes)),
              ),
          ],
        );
      default:
        final faded = Theme.of(context).colorScheme.onSurface.withValues(alpha: .6);
        final labelStyle = TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: faded);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('MAX SPEND PER QUEST', style: labelStyle),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final amount in _budgetOptions)
                  SqChoiceChip(
                    label: amount == 0
                        ? 'Free only'
                        : amount == 30
                        ? '\$30+'
                        : '\$${amount.toStringAsFixed(0)}',
                    selected: _preferences.budgetMax == amount,
                    selectedColor: AppColors.secondary,
                    onSelected: (_) => setState(() => _preferences = _preferences.copyWith(budgetMax: amount)),
                  ),
              ],
            ),
            const SizedBox(height: 22),
            Text('SOCIAL VIBE', style: labelStyle),
            const SizedBox(height: 10),
            Row(
              children: [
                for (final (value, emoji, label) in const [
                  ('solo', '🎧', 'Solo'),
                  ('social', '👥', 'Social'),
                  ('group', '🎉', 'Group'),
                ]) ...[
                  if (value != 'solo') const SizedBox(width: 8),
                  Expanded(
                    child: _SocialVibeCard(
                      emoji: emoji,
                      label: label,
                      selected: _preferences.socialLevel == value,
                      onTap: () => setState(() => _preferences = _preferences.copyWith(socialLevel: value)),
                    ),
                  ),
                ],
              ],
            ),
          ],
        );
    }
  }
}

String _capitalize(String value) => value.isEmpty ? value : value[0].toUpperCase() + value.substring(1);

/// Kotlin's DifficultyOption: a bordered card that fills indigo when picked.
class _DifficultyOption extends StatelessWidget {
  final String emoji;
  final String label;
  final String description;
  final bool selected;
  final VoidCallback onTap;

  const _DifficultyOption({
    required this.emoji,
    required this.label,
    required this.description,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return SqOutlinedCard(
      onTap: onTap,
      padding: const EdgeInsets.all(18),
      color: selected ? AppColors.primary : null,
      borderColor: selected ? Colors.transparent : null,
      child: Row(
        children: [
          Text(emoji, style: const TextStyle(fontSize: 30)),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: selected ? Colors.white : onSurface,
                  ),
                ),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 12,
                    color: selected ? Colors.white.withValues(alpha: .74) : onSurface.withValues(alpha: .6),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One of the three "Social vibe" cards of the last step.
class _SocialVibeCard extends StatelessWidget {
  final String emoji;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _SocialVibeCard({required this.emoji, required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SqTintCard(
      onTap: onTap,
      radius: 18,
      padding: const EdgeInsets.symmetric(vertical: 14),
      color: selected ? AppColors.primary : scheme.primaryContainer,
      child: Column(
        children: [
          Text(emoji, style: const TextStyle(fontSize: 24)),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: selected ? Colors.white : scheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}
