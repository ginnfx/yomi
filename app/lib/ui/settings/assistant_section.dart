import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/ai_controller.dart';
import '../../state/settings.dart';
import 'settings_widgets.dart';

/// Turns "Ask Yomi" on or off and says what it shares.
class AssistantSection extends StatelessWidget {
  const AssistantSection({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsController>();
    final isAvailable = context.watch<AiController>().isAvailable;
    return SettingsGroup(
      title: 'Assistant',
      footer: isAvailable
          ? 'Ask for music in your own words: it plays what you have, finds the '
                'rest on YouTube, and can request songs to add. Only what you type '
                'and your top artists and moods are sent, never your messages or '
                'history.'
          : "The server's AI isn't set up, so the assistant isn't available.",
      children: [
        SettingsSwitch(
          title: 'Ask Yomi',
          subtitle: 'A music assistant on Home and Search',
          value: isAvailable && settings.isAssistantOn,
          onChanged: isAvailable ? settings.setAssistantOn : (_) {},
        ),
      ],
    );
  }
}
