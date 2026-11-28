import 'package:flutter/material.dart';

import '../../core/app_theme.dart';

/// Sponsored quests are always shown labelled as sponsored, wherever a quest
/// appears (shared rule in Sidequests-Backend docs/API_CONTRACT.md; Kotlin
/// shows a "SPONSORED" pill). With [showSponsorName] it also says who pays for
/// it: "Patrocinada por Boulder Box".
///
/// Dark text on a solid amber pill, so it stays readable on light and dark
/// cards alike.
class SponsoredBadge extends StatelessWidget {
  static const label = 'Sponsored';

  final String? sponsorName;
  final bool showSponsorName;

  const SponsoredBadge({super.key, this.sponsorName, this.showSponsorName = false});

  String get text {
    final name = sponsorName?.trim();
    if (!showSponsorName || name == null || name.isEmpty) return label;
    return '$label by $name';
  }

  @override
  Widget build(BuildContext context) {
    // Kotlin's MetaPill on amber at 22–28 % (QuestCard / QuestDetail).
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.amber.withValues(alpha: showSponsorName ? .28 : .22),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: Theme.of(context).colorScheme.onSurface,
        ),
      ),
    );
  }
}
