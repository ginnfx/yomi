import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/session.dart';
import '../theme.dart';
import '../pages/connection_doctor_page.dart';
import 'settings_widgets.dart';

/// Home and away addresses, and how Yomi chooses between them.
class ConnectionSection extends StatefulWidget {
  const ConnectionSection({super.key});

  @override
  State<ConnectionSection> createState() => _ConnectionSectionState();
}

class _ConnectionSectionState extends State<ConnectionSection> {
  late final TextEditingController _home = TextEditingController(
    text: context.read<SessionController>().homeUrl,
  );
  late final TextEditingController _away = TextEditingController(
    text: context.read<SessionController>().awayUrl,
  );
  bool _isSaving = false;

  @override
  void dispose() {
    _home.dispose();
    _away.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final session = context.read<SessionController>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _isSaving = true);
    await session.updateConnection(home: _home.text, away: _away.text);
    if (!mounted) return;
    setState(() => _isSaving = false);
    _home.text = session.homeUrl;
    _away.text = session.awayUrl;
    messenger.showSnackBar(
      SnackBar(content: Text('Saved. Using: ${session.routeLabel}')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionController>();
    final isHome = session.route == ActiveRoute.home;
    return SettingsGroup(
      title: 'Connection',
      children: [
        SettingsInfoRow(
          icon: isHome ? Icons.home_rounded : Icons.public_rounded,
          title: session.isResolving
              ? 'Checking…'
              : 'Using: ${session.routeLabel}',
          detail: session.serverUrl,
          action: TextButton(
            onPressed: session.isResolving ? null : session.refreshRoute,
            child: const Text('Check now'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: SizedBox(
            width: double.infinity,
            child: SegmentedButton<RouteMode>(
              showSelectedIcon: false,
              style: SegmentedButton.styleFrom(
                selectedBackgroundColor: context.accent,
                selectedForegroundColor: context.onAccent,
                textStyle: yomiText(13, weight: FontWeight.w700),
              ),
              segments: const [
                ButtonSegment(value: RouteMode.auto, label: Text('Automatic')),
                ButtonSegment(
                  value: RouteMode.home,
                  label: Text('Always home'),
                ),
                ButtonSegment(
                  value: RouteMode.away,
                  label: Text('Always away'),
                ),
              ],
              selected: {session.mode},
              onSelectionChanged: (modes) =>
                  session.updateConnection(mode: modes.first),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 12),
          child: TextField(
            controller: _home,
            keyboardType: TextInputType.url,
            autocorrect: false,
            style: yomiText(15, weight: FontWeight.w600),
            decoration: const InputDecoration(
              labelText: 'Home address',
              hintText: '192.168.1.18  (optional)',
              prefixIcon: Icon(Icons.home_rounded),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TextField(
            controller: _away,
            keyboardType: TextInputType.url,
            autocorrect: false,
            style: yomiText(15, weight: FontWeight.w600),
            decoration: const InputDecoration(
              labelText: 'Away address',
              hintText: '100.x.x.x  (Tailscale)',
              prefixIcon: Icon(Icons.public_rounded),
            ),
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.medical_services_outlined),
          title: Text(
            'Connection doctor',
            style: yomiText(15, weight: FontWeight.w700),
          ),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => openConnectionDoctor(context),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: _isSaving ? null : _save,
              child: _isSaving
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: context.onAccent,
                      ),
                    )
                  : const Text('Save addresses'),
            ),
          ),
        ),
      ],
    );
  }
}
