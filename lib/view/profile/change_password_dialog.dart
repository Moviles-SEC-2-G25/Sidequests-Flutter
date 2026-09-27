import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../viewmodel/auth/auth_view_model.dart';

/// Lets a signed-in user set a new password (Supabase `auth.updateUser`).
Future<void> showChangePasswordDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const _ChangePasswordDialog(),
  );
}

class _ChangePasswordDialog extends StatefulWidget {
  const _ChangePasswordDialog();

  @override
  State<_ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<_ChangePasswordDialog> {
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  String? _error;
  bool _isSaving = false;

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final password = _passwordController.text;
    if (password.length < 6) {
      setState(() => _error = 'Mínimo 6 caracteres');
      return;
    }
    if (password != _confirmController.text) {
      setState(() => _error = 'Las contraseñas no coinciden');
      return;
    }
    setState(() {
      _isSaving = true;
      _error = null;
    });
    final messenger = ScaffoldMessenger.of(context);
    final error = await context.read<AuthViewModel>().changePassword(password);
    if (!mounted) return;
    if (error != null) {
      setState(() {
        _isSaving = false;
        _error = error;
      });
      return;
    }
    Navigator.of(context).pop();
    messenger.showSnackBar(
      const SnackBar(content: Text('Contraseña actualizada')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Cambiar contraseña'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _passwordController,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Nueva contraseña'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _confirmController,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Confirmar contraseña',
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _isSaving ? null : _save,
          child: const Text('Guardar'),
        ),
      ],
    );
  }
}
