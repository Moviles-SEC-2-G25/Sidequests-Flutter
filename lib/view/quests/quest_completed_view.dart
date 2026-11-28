import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
import '../../core/category_labels.dart';
import '../../models/quest.dart';
import '../../models/user_quest.dart';
import '../../viewmodel/quests/quest_view_model.dart';
import '../widgets/sq_components.dart';
import 'quest_detail_view.dart';

/// "Tell us more" follows the stars: what went wrong for a low rating, what
/// was so-so for a middling one, what was good for a high one (the Kotlin
/// app's tags). Saved as shown, in English, like Kotlin saves them.
List<String> feedbackTagsFor(int rating) => switch (rating) {
  <= 0 => const [],
  1 || 2 => const ['Too long', 'Too expensive', 'Hard to find', 'Not much fun', 'Too difficult', 'Bad weather'],
  3 => const ['It was okay', 'A bit tough', 'A bit long', 'Worth trying', 'Could be better'],
  _ => const ['Worth it', 'Would do again', 'Felt proud', 'Relaxing', 'Surprising', 'Fun'],
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

  @override
  void initState() {
    super.initState();
    context.read<QuestViewModel>().clearRatingError();
  }

  Future<void> _save(QuestViewModel questViewModel) async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final success = await questViewModel.submitRating(
      widget.mission,
      rating: _rating,
      // Keep the chip order stable regardless of tap order.
      tags: feedbackTagsFor(_rating).where(_tags.contains).toList(),
    );
    if (success && questViewModel.ratingQueued) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Rating saved on the phone: it will be sent when you reconnect')),
      );
    }
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
            // Kotlin's RatingScreen: centered column, 20 dp sides, 24 dp top/bottom.
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
            child: Column(
              children: [
                Text(widget.quest.emoji ?? '🎯', style: const TextStyle(fontSize: 64)),
                Text(
                  'Quest completed!',
                  style: textTheme.labelLarge?.copyWith(color: AppColors.secondary),
                ),
                Text(widget.quest.title, textAlign: TextAlign.center, style: textTheme.titleLarge),
                const SizedBox(height: 20),
                Text('How was it?', style: textTheme.titleMedium),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(5, (index) {
                    final filled = index < _rating;
                    // Kotlin draws the stars as ★ / ☆ glyphs, primary when filled.
                    return IconButton(
                      tooltip: '${index + 1}',
                      onPressed: isSaving
                          ? null
                          : () => setState(() {
                              _rating = index + 1;
                              // Tags of another rating no longer apply.
                              _tags.retainAll(feedbackTagsFor(_rating));
                            }),
                      icon: Text(
                        filled ? '★' : '☆',
                        style: TextStyle(
                          fontSize: 30,
                          color: filled
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    );
                  }),
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _rating == 0
                        ? 'Pick your stars to tell us more (optional)'
                        : _rating <= 2
                        ? 'What went wrong? (optional)'
                        : _rating == 3
                        ? 'What could be better? (optional)'
                        : 'What did you like? (optional)',
                    style: textTheme.bodySmall,
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final tag in feedbackTagsFor(_rating))
                        SqChoiceChip(
                          label: tag,
                          selected: _tags.contains(tag),
                          onSelected: isSaving
                              ? null
                              : (_) => setState(() => _tags.contains(tag) ? _tags.remove(tag) : _tags.add(tag)),
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
                _SimilarQuestsSection(completed: widget.quest, rating: _rating),
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
                        : Text(error == null ? 'Save' : 'Retry'),
                  ),
                ),
                TextButton(
                  onPressed: isSaving ? null : () => Navigator.of(context).pop(),
                  child: const Text('Skip'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "Te podría gustar": up to 3 quests ranked by SimilarQuestRecommender. It
/// tracks the pending (not-yet-saved) rating as the user taps stars: each new
/// rating is ranked by a worker isolate, off the UI thread, and the section
/// repaints when the answer arrives (keeping the previous list meanwhile).
class _SimilarQuestsSection extends StatelessWidget {
  final Quest completed;
  final int rating;

  const _SimilarQuestsSection({required this.completed, required this.rating});

  @override
  Widget build(BuildContext context) {
    final questViewModel = context.watch<QuestViewModel>();
    final similar = questViewModel.similarQuestsFor(completed: completed, rating: rating);
    if (similar.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('You might also like', style: Theme.of(context).textTheme.titleMedium),
          for (final (index, quest) in similar.indexed)
            _SimilarQuestCard(
              quest: quest,
              onTap: () {
                questViewModel.trackSimilarQuestOpened(
                  openedQuestId: quest.id,
                  sourceQuestId: completed.id,
                  rank: index + 1,
                );
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => QuestDetailView(quest: quest, wasRecommended: true),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

class _SimilarQuestCard extends StatelessWidget {
  final Quest quest;
  final VoidCallback onTap;

  const _SimilarQuestCard({required this.quest, required this.onTap});

  @override
  Widget build(BuildContext context) {
    // Kotlin's suggestion card: plain 16 dp card, emoji + title + "category · duration".
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(quest.emoji ?? '🎯', style: const TextStyle(fontSize: 24)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(quest.title, style: textTheme.titleSmall),
                      Text(
                        '${categoryLabelEs(quest.category)} · ${quest.durationMinutes} min',
                        style: textTheme.bodySmall,
                      ),
                    ],
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
