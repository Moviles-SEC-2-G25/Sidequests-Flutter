import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
import '../../viewmodel/auth/auth_view_model.dart';

/// Shown by AuthGate instead of HomeShell while the session is biometric-
/// locked. Prompts on open; falls back to "Usar contraseña" (sign out).
class BiometricLockView extends StatefulWidget {
  const BiometricLockView({super.key});

  @override
  State<BiometricLockView> createState() => _BiometricLockViewState();
}

class _BiometricLockViewState extends State<BiometricLockView> {
  bool _isPrompting = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _prompt());
  }

  Future<void> _prompt() async {
    if (_isPrompting) return;
    final authViewModel = context.read<AuthViewModel>();
    setState(() {
      _isPrompting = true;
      _failed = false;
    });
    // On success the view model unlocks and AuthGate swaps this view out.
    final success = await authViewModel.unlock();
    if (!mounted || success) return;
    setState(() {
      _isPrompting = false;
      _failed = true;
    });
  }

  /// Signing out is the way to the password, and offline that way back in is
  /// closed: only then does it ask first.
  Future<void> _usePassword() async {
    final authViewModel = context.read<AuthViewModel>();
    if (await authViewModel.isOffline()) {
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          content: const Text(
            'Sin conexión no podrás iniciar sesión con tu contraseña hasta reconectar. '
            '¿Salir de todos modos?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancelar'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Salir'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    await authViewModel.signOut();
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.fingerprint, size: 72, color: AppColors.primary),
                const SizedBox(height: 16),
                Text('Sidequests bloqueada', style: textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(
                  _failed
                      ? 'No se pudo verificar tu huella.'
                      : 'Usa tu huella para continuar.',
                  textAlign: TextAlign.center,
                  style: textTheme.bodySmall?.copyWith(
                    color: _failed ? Theme.of(context).colorScheme.error : null,
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _isPrompting ? null : _prompt,
                    icon: const Icon(Icons.fingerprint),
                    label: Text(_failed ? 'Reintentar' : 'Desbloquear'),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: _isPrompting ? null : _usePassword,
                    child: const Text('Usar contraseña'),
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
