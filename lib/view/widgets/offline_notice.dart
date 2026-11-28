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
      'Sin conexión: puedes ver las misiones guardadas, pero necesitas internet para empezar una.';
  static const startMission =
      'Sin conexión: necesitas internet para iniciar esta misión. Puedes ver sus detalles mientras tanto.';
  static const missionProgress =
      'Sin conexión: puedes revisar tu misión, pero necesitas internet para completar pasos. '
      'Tu avance está guardado.';
  static const photoUpload = 'Tu foto está guardada en el teléfono y se subirá cuando vuelvas a tener conexión.';
  static const savePreferences = 'Sin conexión: necesitas internet para guardar tus preferencias.';
  static const attemptEvidence =
      'Sin conexión: ves las fotos guardadas en tu teléfono. Las demás estarán disponibles al reconectar, '
      'y necesitas internet para guardarlas.';
  static const offlinePackPending =
      'Sin conexión: la misión se descargará cuando vuelvas a tener internet.';
  static const offlinePackRetry =
      'Sin conexión: podrás reintentar las descargas cuando vuelvas a tener internet.';

  /// Retos en grupo: the lists on screen are the ones saved on the phone;
  /// create, join and steps need the server (they're never queued).
  static const groupChallenges = 'Retos cargados antes · conéctate para hacer cambios.';
  static const groupChallengesNothingSaved =
      'Sin conexión: conéctate para ver los retos en grupo y hacer cambios.';

  /// ES13: a "¿Cómo te sientes hoy?" chip tapped while the list on screen is
  /// the saved one; [level] is the chip's name ("En grupo").
  static String awaitingSocialLevel(String level) =>
      "Sin conexión: estas son tus últimas recomendaciones. Aplicaremos '$level' al reconectar.";
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
