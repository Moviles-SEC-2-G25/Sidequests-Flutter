import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../viewmodel/auth/auth_view_model.dart';
import '../widgets/offline_notice.dart';
import 'login_view.dart';

/// Kotlin's AuthScreen in "create account" mode: same layout as LoginView,
/// "Create your account" headline, and a link back to logging in.
class SignUpView extends StatefulWidget {
  const SignUpView({super.key});

  @override
  State<SignUpView> createState() => _SignUpViewState();
}

class _SignUpViewState extends State<SignUpView> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final authViewModel = context.watch<AuthViewModel>();
    final isBusy = authViewModel.status == AuthStatus.authenticating;
    final isOffline = watchIsOffline(context);

    return AuthScaffold(
      title: 'Create your account',
      children: [
        TextField(
          controller: _emailController,
          keyboardType: TextInputType.emailAddress,
          enabled: !isBusy,
          decoration: const InputDecoration(labelText: 'Email'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _passwordController,
          obscureText: true,
          enabled: !isBusy,
          decoration: const InputDecoration(labelText: 'Password'),
        ),
        if (isOffline) ...[
          const SizedBox(height: 16),
          const OfflineNotice(message: AuthViewModel.offlineSignUpMessage),
        ] else if (authViewModel.errorMessage != null) ...[
          const SizedBox(height: 16),
          AuthNoticeCard.error(body: authViewModel.errorMessage!),
        ],
        const SizedBox(height: 20),
        FilledButton(
          onPressed: isBusy || isOffline
              ? null
              : () async {
                  final success = await authViewModel.signUp(
                    email: _emailController.text.trim(),
                    password: _passwordController.text,
                  );
                  if (success && context.mounted) {
                    Navigator.of(context).pop();
                  }
                },
          child: const Text('Create account'),
        ),
        if (isBusy) ...const [
          SizedBox(height: 16),
          Align(alignment: Alignment.centerLeft, child: CircularProgressIndicator()),
        ],
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: isBusy ? null : () => Navigator.of(context).pop(),
            child: const Text('Already have an account? Log in'),
          ),
        ),
      ],
    );
  }
}
