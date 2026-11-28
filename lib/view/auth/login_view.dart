import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../viewmodel/auth/auth_view_model.dart';
import '../widgets/offline_notice.dart';
import 'otp_login_view.dart';
import 'signup_view.dart';

/// Kotlin's AuthScreen (log-in mode): no app bar, a big indigo "Sidequests"
/// title, filled inputs, the primary button, "Log in with a code" and the
/// link to create an account.
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

    return AuthScaffold(
      title: 'Sidequests',
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
          const OfflineNotice(message: AuthViewModel.offlineSignInMessage),
        ] else if (authViewModel.errorMessage != null) ...[
          const SizedBox(height: 16),
          AuthNoticeCard.error(body: authViewModel.errorMessage!),
        ],
        const SizedBox(height: 20),
        FilledButton(
          onPressed: isBusy || isOffline
              ? null
              : () => authViewModel.signIn(
                  email: _emailController.text.trim(),
                  password: _passwordController.text,
                ),
          child: const Text('Log in'),
        ),
        if (isBusy) ...const [
          SizedBox(height: 16),
          Align(alignment: Alignment.centerLeft, child: CircularProgressIndicator()),
        ],
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: isBusy
              ? null
              : () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const OtpLoginView()),
                ),
          child: const Text('Log in with a code'),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: isBusy
                ? null
                : () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const SignUpView()),
                  ),
            child: const Text("Don't have an account? Sign up"),
          ),
        ),
      ],
    );
  }
}

/// The layout every Kotlin auth screen shares: background color, scrolling
/// column with 24 dp sides and 40 dp top/bottom, centered vertically, and the
/// black-weight indigo headline.
class AuthScaffold extends StatelessWidget {
  final String title;
  final List<Widget> children;

  /// Kotlin's EmailCodeScreen starts with a "Back" text button above the title.
  final VoidCallback? onBack;

  /// False: a regular headline (Kotlin's EmailCodeScreen), not the indigo one.
  final bool brandTitle;

  const AuthScaffold({
    super.key,
    required this.title,
    required this.children,
    this.onBack,
    this.brandTitle = true,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: (constraints.maxHeight - 80).clamp(0, double.infinity)),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (onBack != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(onPressed: onBack, child: const Text('Back')),
                    ),
                  Text(
                    title,
                    style: brandTitle
                        ? textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.w900,
                            color: Theme.of(context).colorScheme.primary,
                          )
                        : textTheme.headlineMedium,
                  ),
                  SizedBox(height: brandTitle ? 28 : 14),
                  ...children,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Kotlin's AuthNoticeCard: emoji, bold title and body on a tinted card.
class AuthNoticeCard extends StatelessWidget {
  final String emoji;
  final String title;
  final String body;
  final Color? color;
  final Color? contentColor;

  const AuthNoticeCard({
    super.key,
    required this.emoji,
    required this.title,
    required this.body,
    this.color,
    this.contentColor,
  });

  /// "⚠️ Something went wrong" on the error container.
  const AuthNoticeCard.error({super.key, required this.body, this.title = 'Something went wrong'})
    : emoji = '⚠️',
      color = null,
      contentColor = null;

  /// "✉️ Almost there" on a light teal card.
  const AuthNoticeCard.info({super.key, required this.body, this.title = 'Almost there'})
    : emoji = '✉️',
      color = const Color(0x242AB7A9),
      contentColor = null;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final isError = color == null;
    final foreground = contentColor ?? (isError ? scheme.onErrorContainer : scheme.onSurface);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: color ?? scheme.errorContainer,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(emoji, style: const TextStyle(fontSize: 22)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700, color: foreground),
                ),
                const SizedBox(height: 2),
                Text(body, style: textTheme.bodyMedium?.copyWith(color: foreground)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
