import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/ai_controller.dart';
import '../../state/assistant_controller.dart';
import '../../state/settings.dart';
import '../theme.dart';
import 'settings_widgets.dart';

/// Turns "Ask Yomi" on or off, and decides where else the AI is allowed to help.
class AssistantSection extends StatelessWidget {
  const AssistantSection({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsController>();
    final isAvailable = context.watch<AiController>().isAvailable;
    final isOn = isAvailable && settings.isAssistantOn;
    return Column(
      children: [
        SettingsGroup(
          title: 'Assistant',
          footer: isAvailable
              ? 'Ask for music in your own words: it plays what you have, finds '
                    'the rest on YouTube, and can request songs to add. Only what '
                    'you type is sent, never your messages or history.'
              : "The server's AI isn't set up, so the assistant isn't available.",
          children: [
            SettingsSwitch(
              title: 'Ask Yomi',
              subtitle: 'A music assistant on Home and Search',
              value: isOn,
              onChanged: isAvailable ? settings.setAssistantOn : (_) {},
            ),
            if (isOn) const _ClearConversation(),
          ],
        ),
        if (isAvailable)
          SettingsGroup(
            title: 'Where AI helps',
            footer:
                'Turn any of these off and that part of Yomi works from your '
                'library alone.',
            children: [
              SettingsSwitch(
                title: 'Understand searches',
                subtitle: 'Search for a mood or a description, not just names',
                value: settings.isAiSearchOn,
                onChanged: settings.setAiSearchOn,
              ),
              SettingsSwitch(
                title: 'Suggest songs on Home',
                subtitle: 'A weekly "You might like" from outside your library',
                value: settings.isDiscoverOn,
                onChanged: settings.setDiscoverOn,
              ),
              SettingsSwitch(
                title: 'Use my taste',
                subtitle:
                    'Send your top artists and moods with questions, so '
                    'answers fit you',
                value: settings.sendsTasteToAssistant,
                onChanged: settings.setSendsTasteToAssistant,
              ),
            ],
          ),
      ],
    );
  }
}

class _ClearConversation extends StatelessWidget {
  const _ClearConversation();

  @override
  Widget build(BuildContext context) {
    final assistant = context.watch<AssistantController>();
    final hasConversation = assistant.turns.isNotEmpty;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.delete_sweep_rounded),
      title: Text(
        'Clear the conversation',
        style: yomiText(15, weight: FontWeight.w700),
      ),
      subtitle: Text(
        hasConversation
            ? 'Start Ask Yomi from a blank page'
            : 'Nothing to clear right now',
        style: yomiText(
          12.5,
          weight: FontWeight.w500,
          color: YomiColors.textSecondary,
        ),
      ),
      enabled: hasConversation && !assistant.isThinking,
      onTap: assistant.clear,
    );
  }
}
