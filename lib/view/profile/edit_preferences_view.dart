import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/category_labels.dart';
import '../../models/user_preferences.dart';
import '../../viewmodel/profile/profile_view_model.dart';

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
    final saved = await context.read<ProfileViewModel>().updatePreferences(_preferences);
    if (!mounted) return;
    if (saved) {
      Navigator.of(context).pop();
    } else {
      setState(() => _isSaving = false);
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
    return Scaffold(
      appBar: AppBar(title: const Text('Mis preferencias')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text('Intereses', style: Theme.of(context).textTheme.titleMedium),
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
          Text('Dificultad preferida', style: Theme.of(context).textTheme.titleMedium),
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
          Text('Nivel social', style: Theme.of(context).textTheme.titleMedium),
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
          Text('Modo de ubicación', style: Theme.of(context).textTheme.titleMedium),
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
            'Tiempo típico disponible: ${_preferences.typicalTimeMinutes} min',
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
          FilledButton(
            onPressed: _isSaving ? null : _save,
            child: _isSaving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Text('Guardar'),
          ),
        ],
      ),
    );
  }
}
