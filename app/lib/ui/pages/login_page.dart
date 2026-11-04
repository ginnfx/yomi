import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/friendly_error.dart';
import '../../core/server_defaults.dart';
import '../../state/session.dart';
import '../widgets/error_view.dart';
import '../settings/invite_section.dart';
import '../theme.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _server = TextEditingController(text: defaultServerUrl);
  final _user = TextEditingController();
  final _password = TextEditingController();
  final _home = TextEditingController(text: defaultHomeServerUrl);
  bool _isBusy = false;
  bool _showPassword = false;
  FriendlyError? _error;

  @override
  void dispose() {
    _server.dispose();
    _user.dispose();
    _password.dispose();
    _home.dispose();
    super.dispose();
  }

  Future<void> _useInvite() async {
    final messenger = ScaffoldMessenger.of(context);
    final host = Uri.tryParse(normalizeServerUrl(_server.text))?.host ?? '';
    if (await showInviteDialog(context, host)) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Connected. Now sign in.')),
      );
    }
  }

  Future<void> _submit() async {
    if (_isBusy) return;
    final session = context.read<SessionController>();
    setState(() {
      _isBusy = true;
      _error = null;
    });
    try {
      await session.signIn(
        _server.text,
        _user.text,
        _password.text,
        homeInput: _home.text,
      );
    } on Exception catch (error) {
      if (mounted) setState(() => _error = describeFailure(context, error));
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PageBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(28),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Yomi',
                      textAlign: TextAlign.center,
                      style: yomiText(
                        56,
                        weight: FontWeight.w800,
                        letterSpacing: -2,
                        color: context.accent,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'One account. Your music, everywhere.',
                      textAlign: TextAlign.center,
                      style: yomiText(
                        16,
                        weight: FontWeight.w600,
                        color: YomiColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 44),
                    TextField(
                      controller: _user,
                      autofillHints: const [AutofillHints.username],
                      autocorrect: false,
                      enableSuggestions: false,
                      textCapitalization: TextCapitalization.none,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(labelText: 'Username'),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: _password,
                      autofillHints: const [AutofillHints.password],
                      obscureText: !_showPassword,
                      autocorrect: false,
                      enableSuggestions: false,
                      textCapitalization: TextCapitalization.none,
                      onSubmitted: (_) => _submit(),
                      decoration: InputDecoration(
                        labelText: 'Password',
                        suffixIcon: IconButton(
                          icon: Icon(
                            _showPassword
                                ? Icons.visibility_off_rounded
                                : Icons.visibility_rounded,
                          ),
                          onPressed: () =>
                              setState(() => _showPassword = !_showPassword),
                        ),
                      ),
                    ),
                    Theme(
                      data: Theme.of(context)
                          .copyWith(dividerColor: Colors.transparent),
                      child: ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        title: Text(
                          'Advanced connection settings',
                          style: yomiText(
                            14,
                            weight: FontWeight.w700,
                            color: YomiColors.textSecondary,
                          ),
                        ),
                        childrenPadding: const EdgeInsets.only(bottom: 6),
                        children: [
                          TextField(
                            controller: _server,
                            keyboardType: TextInputType.url,
                            autocorrect: false,
                            decoration: const InputDecoration(
                              labelText: 'Server address',
                            ),
                          ),
                          const SizedBox(height: 14),
                          TextField(
                            controller: _home,
                            keyboardType: TextInputType.url,
                            autocorrect: false,
                            decoration: const InputDecoration(
                              labelText: 'Address on your home Wi-Fi',
                              hintText: '192.168.1.18',
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_error != null)
                      Container(
                        margin: const EdgeInsets.only(top: 8),
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.redAccent.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _error!.title,
                              style: yomiText(
                                15,
                                weight: FontWeight.w800,
                                color: Colors.redAccent,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              _error!.hint,
                              style: yomiText(
                                13,
                                weight: FontWeight.w500,
                                color: YomiColors.textSecondary,
                                height: 1.35,
                              ),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 24),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                      ),
                      onPressed: _isBusy ? null : _submit,
                      child: _isBusy
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.black,
                              ),
                            )
                          : Text(
                              'Sign in',
                              style: yomiText(
                                16,
                                weight: FontWeight.w800,
                                color: Colors.black,
                              ),
                            ),
                    ),
                    const SizedBox(height: YomiSpace.s),
                    TextButton(
                      onPressed: _isBusy ? null : _useInvite,
                      child: const Text('Have an invite code?'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
