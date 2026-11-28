import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
import '../../viewmodel/context/context_status_view_model.dart';

/// Context-aware banner: adapts to the device's connectivity and battery.
/// Same look as the Kotlin app's DeviceStatusBanner: a full-width strip under
/// the status bar (error / teal / amber) with a bold title and a short body.
/// Offline has priority over the reconnection notice and the low battery.
class ContextBanner extends StatelessWidget {
  const ContextBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final status = context.watch<ContextStatusViewModel>();
    final scheme = Theme.of(context).colorScheme;
    final String title;
    final String body;
    final Color color;
    if (status.isOffline) {
      title = "You're offline";
      body = 'Offline: showing the last saved data. Starting or completing quests requires internet.';
      color = scheme.error;
    } else if (status.justReconnected) {
      title = "You're back online";
      body = 'Connection restored: updating quests.';
      color = AppColors.secondary;
    } else if (status.isLowBattery) {
      title = 'Battery saver';
      body = 'Low battery: using less GPS to save power.';
      color = AppColors.amber;
    } else {
      return const SizedBox.shrink();
    }
    final contentColor = status.isOffline ? scheme.onError : AppColors.onLightAccent;
    final textTheme = Theme.of(context).textTheme;
    return Material(
      color: color,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: SizedBox(
            width: double.infinity,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: textTheme.titleSmall?.copyWith(color: contentColor, fontWeight: FontWeight.w700),
                ),
                Text(body, style: textTheme.bodySmall?.copyWith(color: contentColor)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
