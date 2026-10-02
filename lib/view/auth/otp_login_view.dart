import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../viewmodel/auth/auth_view_model.dart';

enum _OtpStep { email, code }

/// Passwordless sign-in (feature e): email → 6-digit code sent by Supabase
/// → session. Pushed from LoginView on top of AuthGate, so on success it
/// pops back to AuthGate, which has already switched to the app by then.
class OtpLoginView extends StatefulWidget {
  /// Must match Authentication → Providers → Email → "Email OTP Length".
  static const codeLength = 6;

  /// Supabase allows one code per email every 60 s; the resend button
  /// never offers a send the server would reject.
  static const resendCooldown = Duration(seconds: 60);

  const OtpLoginView({super.key});

  @override
  State<OtpLoginView> createState() => _OtpLoginViewState();
}

class _OtpLoginViewState extends State<OtpLoginView> {
  static final _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  final _emailController = TextEditingController();
  final _codeController = TextEditingController();
  _OtpStep _step = _OtpStep.email;
  String _email = '';
  int _secondsLeft = 0;
  Timer? _resendTimer;

  String get _typedEmail => _emailController.text.trim().toLowerCase();
  bool get _isEmailValid => _emailPattern.hasMatch(_typedEmail);
  bool get _isCodeComplete => _codeController.text.length == OtpLoginView.codeLength;

  @override
  void initState() {
    super.initState();
    // Don't greet the user with an error from an earlier attempt.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AuthViewModel>().clearOtpError();
    });
  }

  @override
  void dispose() {
    _resendTimer?.cancel();
    _emailController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _sendCode() async {
    final email = _step == _OtpStep.email ? _typedEmail : _email;
    final sent = await context.read<AuthViewModel>().sendLoginCode(email);
    if (!mounted || !sent) return;
    setState(() {
      _email = email;
      _step = _OtpStep.code;
      _codeController.clear();
    });
    _startCooldown();
  }

  void _startCooldown() {
    _resendTimer?.cancel();
    setState(() => _secondsLeft = OtpLoginView.resendCooldown.inSeconds);
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return timer.cancel();
      setState(() => _secondsLeft--);
      if (_secondsLeft <= 0) timer.cancel();
    });
  }

  Future<void> _verify() async {
    final navigator = Navigator.of(context);
    final authViewModel = context.read<AuthViewModel>();
    final success = await authViewModel.verifyLoginCode(email: _email, code: _codeController.text);
    if (success) {
      // AuthGate (the first route) already shows the app underneath.
      navigator.popUntil((route) => route.isFirst);
    } else if (mounted) {
      _codeController.clear();
      setState(() {});
    }
  }

  void _changeEmail() {
    _resendTimer?.cancel();
    context.read<AuthViewModel>().clearOtpError();
    setState(() {
      _step = _OtpStep.email;
      _secondsLeft = 0;
      _codeController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final authViewModel = context.watch<AuthViewModel>();
    final isVerifying = authViewModel.status == AuthStatus.authenticating;
    final isBusy = authViewModel.isSendingCode || isVerifying;
    final error = authViewModel.otpErrorMessage;

    return Scaffold(
      appBar: AppBar(title: const Text('Entrar con código')),
      body: Center(
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ...switch (_step) {
                    _OtpStep.email => _emailStep(context, isBusy),
                    _OtpStep.code => _codeStep(context, isBusy, isVerifying),
                  },
                  if (error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      error,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _emailStep(BuildContext context, bool isBusy) => [
    Text(
      'Te enviaremos un código de ${OtpLoginView.codeLength} dígitos a tu correo. '
      'Sin contraseña.',
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.bodyMedium,
    ),
    const SizedBox(height: 16),
    TextField(
      controller: _emailController,
      keyboardType: TextInputType.emailAddress,
      autofillHints: const [AutofillHints.email],
      textInputAction: TextInputAction.done,
      decoration: const InputDecoration(labelText: 'Correo'),
      onChanged: (_) => setState(() {}),
      onSubmitted: (_) {
        if (_isEmailValid && !isBusy) _sendCode();
      },
    ),
    const SizedBox(height: 20),
    FilledButton(
      onPressed: _isEmailValid && !isBusy ? _sendCode : null,
      child: isBusy ? const _ButtonSpinner() : const Text('Enviar código'),
    ),
  ];

  List<Widget> _codeStep(BuildContext context, bool isBusy, bool isVerifying) {
    final minutes = _secondsLeft ~/ 60;
    final seconds = (_secondsLeft % 60).toString().padLeft(2, '0');
    return [
      Text(
        'Escribe el código que enviamos a',
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodyMedium,
      ),
      Text(
        _email,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.titleSmall,
      ),
      TextButton(onPressed: isBusy ? null : _changeEmail, child: const Text('Cambiar correo')),
      const SizedBox(height: 8),
      TextField(
        controller: _codeController,
        autofocus: true,
        keyboardType: TextInputType.number,
        autofillHints: const [AutofillHints.oneTimeCode],
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        maxLength: OtpLoginView.codeLength,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.headlineSmall?.copyWith(letterSpacing: 8),
        decoration: const InputDecoration(labelText: 'Código', counterText: ''),
        onChanged: (_) {
          setState(() {});
          // Typing (or pasting) the last digit signs in — no extra tap.
          if (_isCodeComplete && !isBusy) _verify();
        },
      ),
      const SizedBox(height: 20),
      FilledButton(
        onPressed: _isCodeComplete && !isBusy ? _verify : null,
        child: isVerifying ? const _ButtonSpinner() : const Text('Entrar'),
      ),
      const SizedBox(height: 8),
      TextButton(
        onPressed: _secondsLeft > 0 || isBusy ? null : _sendCode,
        child: Text(
          _secondsLeft > 0 ? 'Reenviar código ($minutes:$seconds)' : 'Reenviar código',
        ),
      ),
    ];
  }
}

class _ButtonSpinner extends StatelessWidget {
  const _ButtonSpinner();

  @override
  Widget build(BuildContext context) =>
      const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2));
}
