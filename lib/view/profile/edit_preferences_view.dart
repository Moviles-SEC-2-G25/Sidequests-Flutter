import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/category_labels.dart';
import '../../models/user_preferences.dart';
import '../../viewmodel/profile/profile_view_model.dart';
import '../widgets/offline_notice.dart';
import '../widgets/sq_components.dart';

/// "Editar" on the profile's "Mis preferencias" section. Adds the interests
/// picker the Figma reference shows but the original onboarding flow never
/// collected — interests directly drive `recommend_quests`' interest_match.
class EditPreferencesView extends StatefulWidget {
  const EditPreferencesView({super.key});

  @override
  State<EditPreferencesView> createState() => _EditPreferencesViewState();
}

class _EditPreferencesViewState extends State<EditPreferencesView> {
  static const _difficulties = ['easy', 'medium', 'hard'];
  static const _socialLevels = ['solo', 'social', 'group'];
  static const _locationModes = ['all', 'gps', 'anywhere'];

  late UserPreferences _preferences;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _preferences = context.read<ProfileViewModel>().preferences;
  }

  Future<void> _save() async {
    setState(() => _isSaving = true);
    final profileViewModel = context.read<ProfileViewModel>();
    final saved = await profileViewModel.updatePreferences(_preferences);
    if (!mounted) return;
    if (saved) {
      Navigator.of(context).pop();
    } else {
      // Not saved: the choices stay on screen to try again.
      setState(() => _isSaving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(profileViewModel.errorMessage ?? 'Could not save your preferences.'),
        ),
      );
    }
  }

  void _toggleInterest(String value) {
    final current = _preferences.interests;
    final updated = current.contains(value)
        ? current.where((i) => i != value).toList()
        : [...current, value];
    setState(() => _preferences = _preferences.copyWith(interests: updated));
  }

  @override
  Widget build(BuildContext context) {
    final isOffline = watchIsOffline(context);
    // Kotlin-style secondary screen: "Back" + title instead of an app bar.
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SqBackHeader(title: 'My preferences', onBack: () => Navigator.of(context).maybePop()),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                children: [
                  Text('Interests', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: kInterestOptions
                        .map(
                          (value) => FilterChip(
                            label: Text(categoryLabelEs(value)),
                            selected: _preferences.interests.contains(value),
                            onSelected: (_) => _toggleInterest(value),
                          ),
                        )
                        .toList(),
                  ),
                  const SizedBox(height: 24),
                  Text('Preferred difficulty', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
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
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: _socialLevels
                        .map(
                          (value) => ChoiceChip(
                            label: Text(value),
                            selected: _preferences.socialLevel == value,
                            onSelected: (_) =>
                                setState(() => _preferences = _preferences.copyWith(socialLevel: value)),
                          ),
                        )
                        .toList(),
                  ),
                  const SizedBox(height: 24),
                  Text('Location mode', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: _locationModes
                        .map(
                          (value) => ChoiceChip(
                            label: Text(value),
                            selected: _preferences.locationMode == value,
                            onSelected: (_) =>
                                setState(() => _preferences = _preferences.copyWith(locationMode: value)),
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
                      () => _preferences = _preferences.copyWith(typicalTimeMinutes: value.round()),
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (isOffline) ...[
                    const OfflineNotice(message: OfflineMessages.savePreferences),
                    const SizedBox(height: 12),
                  ],
                  FilledButton(
                    onPressed: _isSaving || isOffline ? null : _save,
                    child: _isSaving
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Text('Save'),
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
