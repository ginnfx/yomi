import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/ai_controller.dart';
import '../../state/assistant_controller.dart';
import '../../state/settings.dart';
import 'assistant_page.dart';

/// Opens "Ask Yomi" when the assistant is on and the server has AI.
class AskYomiButton extends StatelessWidget {
  const AskYomiButton({super.key, this.padding = EdgeInsets.zero});

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    // Screens built without these (in tests, or before sign-in) show nothing.
    final isOn = context.watch<SettingsController?>()?.isAssistantOn ?? false;
    final isAvailable = context.watch<AiController?>()?.isAvailable ?? false;
    final hasAssistant = context.watch<AssistantController?>() != null;
    if (!isOn || !isAvailable || !hasAssistant) return const SizedBox.shrink();
    return Padding(
      padding: padding,
      child: FilledButton.tonalIcon(
        onPressed: () => openAssistant(context),
        icon: const Icon(Icons.auto_awesome_rounded, size: 18),
        label: const Text('Ask Yomi'),
      ),
    );
  }
}
