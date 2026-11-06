import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/session.dart';
import '../../state/tunnel_controller.dart';
import '../theme.dart';
import 'settings_widgets.dart';

/// Asks for an invite code and joins. Returns true when the device joined.
Future<bool> showInviteDialog(BuildContext context, String serverHost) async {
  final joined = await showDialog<bool>(
    context: context,
    builder: (_) => _InviteDialog(serverHost: serverHost),
  );
  return joined ?? false;
}

class _InviteDialog extends StatefulWidget {
  const _InviteDialog({required this.serverHost});

  final String serverHost;

  @override
  State<_InviteDialog> createState() => _InviteDialogState();
}

class _InviteDialogState extends State<_InviteDialog> {
  final _code = TextEditingController();
  String? _error;
  bool _isJoining = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    final tunnel = context.read<TunnelController>();
    final navigator = Navigator.of(context);
    setState(() {
      _isJoining = true;
      _error = null;
    });
    try {
      await tunnel.join(_code.text, widget.serverHost);
      navigator.pop(true);
    } on TunnelException catch (error) {
      if (mounted) {
        setState(() {
          _error = error.message;
          _isJoining = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Invite code', style: yomiText(18, weight: FontWeight.w800)),
      content: TextField(
        controller: _code,
        autocorrect: false,
        enableSuggestions: false,
        style: yomiText(14, weight: FontWeight.w500),
        decoration: InputDecoration(
          hintText: 'Paste the code you were sent',
          errorText: _error,
          errorMaxLines: 3,
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isJoining ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _isJoining ? null : _join,
          child: Text(_isJoining ? 'Connecting…' : 'Join'),
        ),
      ],
    );
  }
}

/// Settings entry for connecting away from home without the Tailscale app.
class InviteSection extends StatelessWidget {
  const InviteSection({super.key});

  @override
  Widget build(BuildContext context) {
    final tunnel = context.watch<TunnelController>();
    final session = context.read<SessionController>();
    return SettingsGroup(
      title: 'Connect from anywhere',
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.vpn_key_outlined),
          title: Text(
            tunnel.isEnrolled
                ? 'Invite saved on this device'
                : 'Use an invite code',
            style: yomiText(15, weight: FontWeight.w700),
          ),
          subtitle: Text(
            tunnel.isEnrolled
                ? 'Yomi connects by itself when it is away from home.'
                : 'No Tailscale app or account needed.',
            style: yomiText(
              12.5,
              weight: FontWeight.w500,
              color: YomiColors.textSecondary,
            ),
          ),
          trailing: tunnel.isEnrolled
              ? TextButton(onPressed: tunnel.leave, child: const Text('Leave'))
              : null,
          onTap: tunnel.isEnrolled
              ? null
              : () async {
                  final host = Uri.tryParse(session.awayUrl)?.host ?? '';
                  if (await showInviteDialog(context, host)) {
                    await session.checkServer();
                  }
                },
        ),
      ],
    );
  }
}
