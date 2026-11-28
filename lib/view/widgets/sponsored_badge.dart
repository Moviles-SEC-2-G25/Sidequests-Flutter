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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: AppColors.amber, borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.star_rounded, size: 12, color: AppColors.textPrimaryLight),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimaryLight,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
