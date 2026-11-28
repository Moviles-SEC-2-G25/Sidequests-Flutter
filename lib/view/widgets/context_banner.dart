import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../viewmodel/context/context_status_view_model.dart';

/// Context-aware banner: adapts to the device's connectivity and battery.
class ContextBanner extends StatelessWidget {
  const ContextBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final status = context.watch<ContextStatusViewModel>();
    final IconData icon;
    final String text;
    final Color color;
    if (status.isOffline) {
      icon = Icons.wifi_off;
      text = 'Offline: you are viewing your saved data. Starting or completing quests requires internet.';
      color = Colors.red.shade700;
    } else if (status.justReconnected) {
      icon = Icons.wifi;
      text = 'Connection restored: updating quests';
      color = Colors.green.shade700;
    } else if (status.isLowBattery) {
      icon = Icons.battery_alert;
      text = 'Low battery: using less GPS to save power';
      color = Colors.orange.shade800;
    } else {
      return const SizedBox.shrink();
    }
    return Material(
      color: color,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(icon, color: Colors.white, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  text,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
