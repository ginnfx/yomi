import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_info.dart';
import '../../state/update_controller.dart';
import '../theme.dart';

/// Bottom of Settings: which version this is, and a way to look for a newer one.
class VersionFooter extends StatefulWidget {
  const VersionFooter({super.key});

  @override
  State<VersionFooter> createState() => _VersionFooterState();
}

class _VersionFooterState extends State<VersionFooter> {
  bool _isChecking = false;

  // Settings is also shown in tests and builds without an update controller.
  UpdateController? get _updates =>
      Provider.of<UpdateController?>(context, listen: false);

  Future<void> _check() async {
    final updates = _updates;
    if (updates == null || _isChecking) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _isChecking = true);
    final result = await updates.checkNow();
    if (!mounted) return;
    setState(() => _isChecking = false);
    messenger.showSnackBar(_messageFor(result, updates));
  }

  SnackBar _messageFor(UpdateCheckResult result, UpdateController updates) =>
      switch (result) {
        UpdateCheckResult.available => SnackBar(
          content: const Text('A new version is ready'),
          action: SnackBarAction(
            label: 'Update',
            onPressed: () => updates.startUpdate(),
          ),
        ),
        UpdateCheckResult.upToDate => const SnackBar(
          content: Text('You have the latest version'),
        ),
        UpdateCheckResult.failed => const SnackBar(
          content: Text("Couldn't check for updates. Try again later."),
        ),
        UpdateCheckResult.unsupported => const SnackBar(
          content: Text('This device gets updates another way'),
        ),
      };

  @override
  Widget build(BuildContext context) {
    if (!appInfo.isKnown) return const SizedBox.shrink();
    final canCheck = _updates != null && _updates!.mode != UpdateMode.disabled;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: YomiSpace.xl),
      child: Column(
        children: [
          SelectableText(
            appInfo.label,
            textAlign: TextAlign.center,
            style: yomiText(
              12.5,
              weight: FontWeight.w500,
              color: YomiColors.textSecondary,
            ),
          ),
          if (canCheck)
            TextButton(
              onPressed: _isChecking ? null : _check,
              child: Text(_isChecking ? 'Checking…' : 'Check for updates'),
            ),
        ],
      ),
    );
  }
}
