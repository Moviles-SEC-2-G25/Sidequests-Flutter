import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../core/completion_likelihood.dart';

/// One colour per level, shared by Explore's labels and "Mis
/// estadísticas"' progress bars so both read the same.
Color completionLevelColor(CompletionLevel level) => switch (level) {
  CompletionLevel.high => AppColors.secondaryDark,
  CompletionLevel.medium => AppColors.amber,
  CompletionLevel.low => AppColors.error,
  CompletionLevel.newForYou => AppColors.primary,
};

/// "Probabilidad de que la termines": the user's own completion rate in a
/// quest's category (see CompletionLikelihood). Styled like Explore's
/// _MetaItem rather than a badge so it doesn't read as one of BQ5's
/// server-side "reasons" chips, and says "Prob." so "Media" isn't mistaken
/// for the difficulty label.
class CompletionLikelihoodLabel extends StatelessWidget {
  final CompletionLevel level;

  const CompletionLikelihoodLabel({super.key, required this.level});

  @override
  Widget build(BuildContext context) {
    final label = switch (level) {
      CompletionLevel.high => 'High chance',
      CompletionLevel.medium => 'Medium chance',
      CompletionLevel.low => 'Low chance',
      CompletionLevel.newForYou => 'New for you',
    };
    // Kotlin's completion MetaPill: teal at 16 %, 11 sp semi-bold.
    return Tooltip(
      message: level == CompletionLevel.newForYou
          ? "You haven't tried enough quests in this category yet"
          : 'Based on how many quests in this category you have finished',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: AppColors.secondary.withValues(alpha: .16),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
      ),
    );
  }
}
