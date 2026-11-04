import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/connectivity_controller.dart';
import '../../state/download_manager.dart';
import '../../state/session.dart';
import '../theme.dart';

/// Slim pill at the top whenever the phone has no connection, or downloads are waiting.
class StatusBanner extends StatelessWidget {
  const StatusBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final isOffline = context.select<ConnectivityController, bool>(
      (c) => c.isOffline,
    );
    final isServerDown = context.select<SessionController, bool>(
      (s) => s.isSignedIn && !s.isServerReachable,
    );
    final waiting = context.select<DownloadManager, String?>(
      (d) => d.pausedReason,
    );
    final isCutOff = isOffline || isServerDown;
    final message = isOffline
        ? "You're offline · saved music still plays"
        : isServerDown
        ? "Can't reach your server · saved music still plays"
        : waiting;
    return AnimatedSize(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      child: message == null
          ? const SizedBox(width: double.infinity)
          : Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: YomiColors.surfaceHigh,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    isCutOff
                        ? Icons.cloud_off_rounded
                        : Icons.hourglass_bottom_rounded,
                    size: 16,
                    color: YomiColors.textSecondary,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      message,
                      style: yomiText(
                        12.5,
                        weight: FontWeight.w600,
                        color: YomiColors.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
