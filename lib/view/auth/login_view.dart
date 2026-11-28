import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../viewmodel/auth/auth_view_model.dart';
import '../widgets/offline_notice.dart';
import 'otp_login_view.dart';
import 'signup_view.dart';

class LoginView extends StatefulWidget {
  const LoginView({super.key});

  @override
  State<LoginView> createState() => _LoginViewState();
}

class _LoginViewState extends State<LoginView> {
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

    return Scaffold(
      appBar: AppBar(title: const Text('Sidequests')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          // Scrolls: with the keyboard open on a small phone it overflowed.
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(labelText: 'Email'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _passwordController,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Password'),
                ),
                if (isOffline) ...[
                  const SizedBox(height: 12),
                  const OfflineNotice(message: AuthViewModel.offlineSignInMessage),
                ] else if (authViewModel.errorMessage != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    authViewModel.errorMessage!,
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: isBusy || isOffline
                      ? null
                      : () => authViewModel.signIn(
                          email: _emailController.text.trim(),
                          password: _passwordController.text,
                        ),
                  child: isBusy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Log in'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: isBusy
                      ? null
                      : () => Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const OtpLoginView()),
                        ),
                  icon: const Icon(Icons.mark_email_read_outlined),
                  label: const Text('Log in with a code'),
                ),
                TextButton(
                  onPressed: isBusy
                      ? null
                      : () => Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const SignUpView()),
                        ),
                  child: const Text("Don't have an account? Sign up"),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
