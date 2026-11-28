import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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
            'While offline you will not be able to log in with your password until you reconnect. '
            'Exit anyway?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Exit'),
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
    // Kotlin's BiometricLockScreen: centered headline, explanation, the
    // error in red, the primary "Unlock" button and a text button out.
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Unlock Sidequests', style: textTheme.headlineMedium),
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 16),
                  child: Text(
                    'Confirm your identity to open your saved session.',
                    textAlign: TextAlign.center,
                    style: textTheme.bodyLarge,
                  ),
                ),
                if (_failed)
                  Text(
                    'Could not verify your fingerprint.',
                    textAlign: TextAlign.center,
                    style: textTheme.bodyLarge?.copyWith(color: Theme.of(context).colorScheme.error),
                  ),
                FilledButton(
                  onPressed: _isPrompting ? null : _prompt,
                  child: Text(_failed ? 'Retry' : 'Unlock'),
                ),
                TextButton(
                  onPressed: _isPrompting ? null : _usePassword,
                  child: const Text('Use password'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
