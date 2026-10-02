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
      CompletionLevel.high => 'Prob. alta',
      CompletionLevel.medium => 'Prob. media',
      CompletionLevel.low => 'Prob. baja',
      CompletionLevel.newForYou => 'Nueva para ti',
    };
    final color = completionLevelColor(level);

    return Tooltip(
      message: level == CompletionLevel.newForYou
          ? 'Aún no has probado suficientes misiones de esta categoría'
          : 'Según cuántas misiones de esta categoría has terminado',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.insights, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
