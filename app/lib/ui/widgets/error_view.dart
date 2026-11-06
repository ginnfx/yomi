import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/friendly_error.dart';
import '../../state/connectivity_controller.dart';
import '../../state/session.dart';
import '../pages/settings_page.dart';
import '../theme.dart';

/// Builds the plain-language explanation for [error] from the app's current network state.
FriendlyError describeFailure(BuildContext context, Object error) {
  final connectivity = context.read<ConnectivityController>();
  final session = context.read<SessionController>();
  return explainError(
    error,
    isOffline: connectivity.isOffline,
    isAtHomeRoute: session.route == ActiveRoute.home,
    hasHomeAddress: session.hasHomeAddress,
    isOnWifi: connectivity.isOnWifi,
  );
}

/// A calm, explanatory error with the right next step, instead of raw exception text.
class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.error, this.onRetry});

  final Object error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final friendly = describeFailure(context, error);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: YomiColors.faint(0.07),
            ),
            child: Icon(
              friendly.action == ErrorAction.none
                  ? Icons.cloud_off_rounded
                  : Icons.wifi_off_rounded,
              color: YomiColors.textSecondary,
              size: 30,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            friendly.title,
            textAlign: TextAlign.center,
            style: yomiText(18, weight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            friendly.hint,
            textAlign: TextAlign.center,
            style: yomiText(
              14,
              weight: FontWeight.w500,
              color: YomiColors.textSecondary,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            alignment: WrapAlignment.center,
            children: [
              if (friendly.action == ErrorAction.retry && onRetry != null)
                FilledButton(
                  onPressed: onRetry,
                  child: const Text('Try again'),
                ),
              if (friendly.action == ErrorAction.openSettings)
                FilledButton(
                  onPressed: () => openSettings(context),
                  child: const Text('Open settings'),
                ),
              if (friendly.action == ErrorAction.openSettings &&
                  onRetry != null)
                TextButton(onPressed: onRetry, child: const Text('Try again')),
            ],
          ),
        ],
      ),
    );
  }
}
