import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/local/local_data_source.dart';
import '../../viewmodel/auth/auth_view_model.dart';
import '../home_shell.dart';
import 'login_view.dart';
import 'onboarding_view.dart';

/// Decides between the auth flow, one-time onboarding and the app shell
/// based on [AuthViewModel]'s session state.
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  @override
  Widget build(BuildContext context) {
    final authViewModel = context.watch<AuthViewModel>();

    switch (authViewModel.status) {
      case AuthStatus.unknown:
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      case AuthStatus.unauthenticated:
      case AuthStatus.authenticating:
        return const LoginView();
      case AuthStatus.authenticated:
        final hasCompletedOnboarding = context.read<LocalDataSource>().hasCompletedOnboarding();
        if (!hasCompletedOnboarding) {
          return OnboardingView(onFinished: () => setState(() {}));
        }
        return const HomeShell();
    }
  }
}
