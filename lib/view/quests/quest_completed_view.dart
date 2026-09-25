import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
import '../../models/quest.dart';
import '../../models/user_quest.dart';
import '../../viewmodel/quests/quest_view_model.dart';

const _feedbackTags = <String, String>{
  'divertida': 'Divertida',
  'muy larga': 'Muy larga',
  'costosa': 'Costosa',
  'repetiría': 'Repetiría',
};

/// "Misión completada": shown right after the last step is completed.
/// A 1-5 rating is required to enable "Guardar"; "Omitir" leaves without rating.
class QuestCompletedView extends StatefulWidget {
  final UserQuest mission;
  final Quest quest;

  const QuestCompletedView({super.key, required this.mission, required this.quest});

  @override
  State<QuestCompletedView> createState() => _QuestCompletedViewState();
}

class _QuestCompletedViewState extends State<QuestCompletedView> {
  int _rating = 0;
  final Set<String> _tags = {};

  Future<void> _save(QuestViewModel questViewModel) async {
    final navigator = Navigator.of(context);
    final success = await questViewModel.submitRating(
      widget.mission,
      rating: _rating,
      // Keep the chip order stable regardless of tap order.
      tags: _feedbackTags.keys.where(_tags.contains).toList(),
    );
    if (success && navigator.mounted) navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final questViewModel = context.watch<QuestViewModel>();
    final isSaving = questViewModel.isSubmittingRating;
    final error = questViewModel.ratingErrorMessage;
    final textTheme = Theme.of(context).textTheme;

    return PopScope(
      canPop: !isSaving,
      child: Scaffold(
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 32, 20, 24),
            child: Column(
              children: [
                Text(widget.quest.emoji ?? '🎯', style: const TextStyle(fontSize: 64)),
                const SizedBox(height: 12),
                Text(
                  '¡Misión completada!',
                  style: textTheme.labelLarge?.copyWith(color: AppColors.secondaryDark),
                ),
                const SizedBox(height: 4),
                Text(widget.quest.title, textAlign: TextAlign.center, style: textTheme.titleLarge),
                const SizedBox(height: 28),
                Text('¿Qué te pareció?', style: textTheme.titleMedium),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(5, (index) {
                    final filled = index < _rating;
                    return IconButton(
                      iconSize: 36,
                      tooltip: '${index + 1}',
                      onPressed: isSaving ? null : () => setState(() => _rating = index + 1),
                      icon: Icon(
                        filled ? Icons.star_rounded : Icons.star_outline_rounded,
                        color: filled ? AppColors.primary : Theme.of(context).colorScheme.outline,
                      ),
                    );
                  }),
                ),
                const SizedBox(height: 20),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Cuéntanos más (opcional)', style: textTheme.bodySmall),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final entry in _feedbackTags.entries)
                        FilterChip(
                          label: Text(entry.value),
                          selected: _tags.contains(entry.key),
                          onSelected: isSaving
                              ? null
                              : (selected) => setState(
                                  () => selected ? _tags.add(entry.key) : _tags.remove(entry.key),
                                ),
                        ),
                    ],
                  ),
                ),
                if (error != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    error,
                    textAlign: TextAlign.center,
                    style: textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error),
                  ),
                ],
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _rating == 0 || isSaving ? null : () => _save(questViewModel),
                    child: isSaving
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(error == null ? 'Guardar' : 'Reintentar'),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: isSaving ? null : () => Navigator.of(context).pop(),
                    child: const Text('Omitir'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
