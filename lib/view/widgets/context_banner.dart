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
      text = 'Sin conexión: las misiones nuevas no cargarán hasta reconectar';
      color = Colors.red.shade700;
    } else if (status.isLowBattery) {
      icon = Icons.battery_alert;
      text = 'Batería baja: usamos menos GPS para ahorrar energía';
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
