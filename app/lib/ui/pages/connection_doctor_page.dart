import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/connection_probe.dart';
import '../../state/session.dart';
import '../theme.dart';

void openConnectionDoctor(BuildContext context) {
  Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => const ConnectionDoctorPage()));
}

/// Tries every known server address and shows which ones work, so a dead address
/// never leaves you locked out. Extra addresses added here are used as backups.
class ConnectionDoctorPage extends StatefulWidget {
  const ConnectionDoctorPage({super.key});

  @override
  State<ConnectionDoctorPage> createState() => _ConnectionDoctorPageState();
}

class _ConnectionDoctorPageState extends State<ConnectionDoctorPage> {
  final _input = TextEditingController();
  Map<String, ProbeResult> _results = const {};
  bool _isRunning = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final session = context.read<SessionController>();
    setState(() => _isRunning = true);
    final urls = session.candidateUrls;
    final results = await session.diagnose();
    if (!mounted) return;
    setState(() {
      _results = {for (var i = 0; i < urls.length; i++) urls[i]: results[i]};
      _isRunning = false;
    });
  }

  Future<void> _add() async {
    final text = _input.text;
    if (text.trim().isEmpty) return;
    await context.read<SessionController>().addExtraUrl(text);
    _input.clear();
    await _run();
  }

  String _label(SessionController s, String url) {
    if (url == s.homeUrl) return 'Home';
    if (url == s.awayUrl) return 'Away (Tailscale)';
    return 'Backup';
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionController>();
    return PageBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Text(
            'Connection doctor',
            style: yomiText(20, weight: FontWeight.w800),
          ),
          actions: [
            if (_isRunning)
              const Padding(
                padding: EdgeInsets.all(16),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else
              IconButton(
                tooltip: 'Check again',
                icon: const Icon(Icons.refresh_rounded),
                onPressed: _run,
              ),
          ],
        ),
        body: ListView(
          padding: EdgeInsets.fromLTRB(
            kPagePadding,
            4,
            kPagePadding,
            MediaQuery.paddingOf(context).bottom + 32,
          ),
          children: [
            for (final url in session.candidateUrls) _row(session, url),
            const SizedBox(height: 16),
            TextField(
              controller: _input,
              keyboardType: TextInputType.url,
              autocorrect: false,
              onSubmitted: (_) => _add(),
              style: yomiText(15, weight: FontWeight.w600),
              decoration: InputDecoration(
                labelText: 'Add a backup address',
                hintText: 'http://my-phone.tailnet.ts.net:4533',
                prefixIcon: const Icon(Icons.add_link_rounded),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.add_rounded),
                  onPressed: _add,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(SessionController session, String url) {
    final result = _results[url];
    final isCurrent = url == session.serverUrl;
    final isExtra = session.extraUrls.contains(url);
    final (icon, color, status) = result == null
        ? (Icons.hourglass_empty_rounded, YomiColors.textSecondary, 'Checking…')
        : result.isOk
        ? (
            Icons.check_circle_rounded,
            Colors.greenAccent,
            '${result.elapsed.inMilliseconds} ms',
          )
        : (Icons.cancel_rounded, Colors.redAccent, result.problem);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: YomiColors.surfaceHigh,
        borderRadius: BorderRadius.circular(16),
      ),
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(
          '${_label(session, url)}${isCurrent ? ' · in use' : ''}',
          style: yomiText(15, weight: FontWeight.w700),
        ),
        subtitle: Text(
          '$url\n$status',
          style: yomiText(
            12.5,
            weight: FontWeight.w500,
            color: YomiColors.textSecondary,
          ),
        ),
        isThreeLine: true,
        trailing: isExtra
            ? IconButton(
                icon: const Icon(Icons.delete_outline_rounded),
                onPressed: () async {
                  await session.removeExtraUrl(url);
                  await _run();
                },
              )
            : (result?.isOk ?? false) && !isCurrent
            ? TextButton(
                onPressed: () => session.useUrl(url),
                child: const Text('Use'),
              )
            : null,
      ),
    );
  }
}
