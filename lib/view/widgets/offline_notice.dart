import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
import '../../viewmodel/context/connectivity_view_model.dart';

/// Whether the device is offline, rebuilding [context] when that changes.
/// False when no [ConnectivityViewModel] is above it (unknown = online).
bool watchIsOffline(BuildContext context) =>
    context.watch<ConnectivityViewModel?>()?.isOffline ?? false;

/// Same as [watchIsOffline], for callbacks (no rebuild).
bool readIsOffline(BuildContext context) =>
    context.read<ConnectivityViewModel?>()?.isOffline ?? false;

/// What each screen says about what's blocked offline, in one place so the
/// same block reads the same everywhere.
abstract final class OfflineMessages {
  static const browseMissions =
      'Offline: you can view saved quests, but you need internet to start one.';
  static const startMission =
      'Offline: you need internet to start this quest. You can view its details in the meantime.';
  static const missionProgress =
      'Offline: you can review your quest, but you need internet to complete steps. '
      'Your progress is saved.';
  static const photoUpload = 'Your photo is saved on the phone and will upload when you are back online.';
  static const savePreferences = 'Offline: you need internet to save your preferences.';
  static const attemptEvidence =
      'Offline: you are viewing the photos saved on your phone. The rest will be available when you reconnect, '
      'and you need internet to save them.';
  static const offlinePackPending =
      'Offline: the quest will download when you are back online.';
  static const offlinePackRetry =
      'Offline: you can retry the downloads when you are back online.';

  /// Retos en grupo: the lists on screen are the ones saved on the phone;
  /// create, join and steps need the server (they're never queued).
  static const groupChallenges = 'Previously loaded challenges · connect to make changes.';
  static const groupChallengesNothingSaved =
      'Offline: connect to see group challenges and make changes.';

  /// ES13: a "¿Cómo te sientes hoy?" chip tapped while the list on screen is
  /// the saved one; [level] is the chip's name ("En grupo").
  static String awaitingSocialLevel(String level) =>
      "Offline: these are your latest recommendations. We'll apply '$level' when you reconnect.";
}

/// Inline card next to an action that needs the internet: says it's blocked
/// and why. Same shape as the other in-screen banners (Explore's context
/// banner, Stats' offline banner).
class OfflineNotice extends StatelessWidget {
  final String message;

  const OfflineNotice({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? AppColors.errorContainerDark : AppColors.errorContainerLight,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.wifi_off, color: AppColors.error, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(message, style: Theme.of(context).textTheme.bodySmall)),
        ],
      ),
    );
  }
}
