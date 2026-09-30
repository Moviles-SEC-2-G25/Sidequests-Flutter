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
                    onPressed: _isPrompting ? null : () => context.read<AuthViewModel>().signOut(),
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
