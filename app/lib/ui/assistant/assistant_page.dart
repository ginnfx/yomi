import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/ai/assistant.dart';
import '../../state/assistant_controller.dart';
import '../../state/player_controller.dart';
import '../../state/session.dart';
import '../theme.dart';
import '../widgets/cover_art.dart';
import '../widgets/report_sheet.dart';
import '../widgets/youtube_play_button.dart';

/// Ideas shown before the first question.
const List<String> _starters = [
  'Something calm for studying',
  'Upbeat songs for a run, no rap',
  'Make me a late-night drive playlist',
  'More like what I played today',
];

void openAssistant(BuildContext context) =>
    Navigator.of(context)
        .push(yomiRoute<void>(builder: (_) => const AssistantPage()));

/// "Ask Yomi": ask for music in your own words.
class AssistantPage extends StatefulWidget {
  const AssistantPage({super.key});

  @override
  State<AssistantPage> createState() => _AssistantPageState();
}

class _AssistantPageState extends State<AssistantPage> {
  final _question = TextEditingController();
  final _scroll = ScrollController();

  @override
  void dispose() {
    _question.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _ask(String text) async {
    final assistant = context.read<AssistantController>();
    _question.clear();
    await assistant.ask(text);
    if (!mounted || !_scroll.hasClients) return;
    await _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: context.motion(YomiMotion.standard),
      curve: YomiMotion.curve,
    );
  }

  @override
  Widget build(BuildContext context) {
    final assistant = context.watch<AssistantController>();
    return PageBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Text('Ask Yomi', style: yomiText(20, weight: FontWeight.w800)),
          actions: [
            if (assistant.turns.isNotEmpty)
              IconButton(
                tooltip: 'Start over',
                icon: const Icon(Icons.refresh_rounded),
                onPressed: assistant.clear,
              ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: assistant.turns.isEmpty
                  ? _Starters(onPicked: _ask)
                  : ListView(
                      controller: _scroll,
                      padding: const EdgeInsets.all(kPagePadding),
                      children: [
                        for (final turn in assistant.turns)
                          turn.isUser
                              ? _Question(text: turn.text)
                              : _Answer(answer: turn.answer!),
                        if (assistant.isThinking) const _Thinking(),
                        if (assistant.error != null)
                          Padding(
                            padding: const EdgeInsets.only(top: YomiSpace.s),
                            child: Text(
                              assistant.error!,
                              style: yomiText(13, color: YomiColors.danger),
                            ),
                          ),
                      ],
                    ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  kPagePadding,
                  YomiSpace.s,
                  kPagePadding,
                  YomiSpace.s,
                ),
                child: TextField(
                  controller: _question,
                  enabled: !assistant.isThinking,
                  maxLength: 500,
                  textInputAction: TextInputAction.send,
                  onSubmitted: _ask,
                  decoration: InputDecoration(
                    counterText: '',
                    hintText: 'Ask for music in your own words',
                    suffixIcon: IconButton(
                      tooltip: 'Ask',
                      icon: Icon(Icons.send_rounded, color: context.accent),
                      onPressed: assistant.isThinking
                          ? null
                          : () => _ask(_question.text),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Starters extends StatelessWidget {
  const _Starters({required this.onPicked});

  final ValueChanged<String> onPicked;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(kPagePadding),
    children: [
      Text(
        'What do you feel like hearing?',
        style: yomiText(22, weight: FontWeight.w800),
      ),
      const SizedBox(height: YomiSpace.m),
      Wrap(
        spacing: YomiSpace.s,
        runSpacing: YomiSpace.s,
        children: [
          for (final starter in _starters)
            ActionChip(
              label: Text(starter),
              onPressed: () => onPicked(starter),
            ),
        ],
      ),
    ],
  );
}

class _Question extends StatelessWidget {
  const _Question({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerRight,
    child: Container(
      margin: const EdgeInsets.symmetric(vertical: YomiSpace.s),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: context.accent,
        borderRadius: BorderRadius.circular(YomiRadius.sheet),
      ),
      child: Text(
        text,
        style: yomiText(15, weight: FontWeight.w600, color: Colors.black),
      ),
    ),
  );
}

class _Thinking extends StatelessWidget {
  const _Thinking();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: YomiSpace.m),
    child: Row(
      children: [
        SizedBox.square(
          dimension: 16,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: context.accent,
          ),
        ),
        const SizedBox(width: YomiSpace.s),
        Text('Thinking…', style: yomiText(14, color: YomiColors.textSecondary)),
      ],
    ),
  );
}

class _Answer extends StatelessWidget {
  const _Answer({required this.answer});

  final ChatAnswer answer;

  @override
  Widget build(BuildContext context) {
    final library = answer.librarySongs;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: YomiSpace.s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (answer.reply.isNotEmpty)
            Text(answer.reply, style: yomiText(15, weight: FontWeight.w500)),
          if (library.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: YomiSpace.s),
              child: Wrap(
                spacing: YomiSpace.s,
                children: [
                  FilledButton.icon(
                    onPressed: () =>
                        context.read<PlayerController>().playQueue(library),
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: Text('Play ${library.length}'),
                  ),
                  if (library.length > 1)
                    OutlinedButton.icon(
                      onPressed: () => _savePlaylist(context),
                      icon: const Icon(Icons.playlist_add_rounded),
                      label: const Text('Save as playlist'),
                    ),
                ],
              ),
            ),
          for (final suggestion in answer.songs)
            _SuggestionRow(suggestion: suggestion),
        ],
      ),
    );
  }

  Future<void> _savePlaylist(BuildContext context) async {
    final session = context.read<SessionController>();
    final messenger = ScaffoldMessenger.of(context);
    final name = answer.playlistName ?? 'From Ask Yomi';
    try {
      await session.client.createPlaylist(
        name,
        songIds: [for (final song in answer.librarySongs) song.id],
      );
      messenger.showSnackBar(SnackBar(content: Text('Saved "$name"')));
    } on Exception catch (error) {
      debugPrint('Could not save the playlist: $error');
      messenger.showSnackBar(
        const SnackBar(content: Text("Couldn't save the playlist. Try again.")),
      );
    }
  }
}

class _SuggestionRow extends StatelessWidget {
  const _SuggestionRow({required this.suggestion});

  final SuggestedSong suggestion;

  @override
  Widget build(BuildContext context) {
    final song = suggestion.song;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: song == null
          ? Icon(Icons.cloud_outlined, color: YomiColors.textSecondary)
          : CoverArt(
              coverArtId: song.coverArtId,
              size: 44,
              radius: YomiRadius.art,
              seed: song.album,
            ),
      title: Text(
        suggestion.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: yomiText(15, weight: FontWeight.w700),
      ),
      subtitle: Text(
        song == null
            ? '${suggestion.artist} · Not in your library'
            : suggestion.artist,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: song == null
          ? null
          : () => context.read<PlayerController>().playQueue([song]),
      trailing: song != null
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                YoutubePlayButton(
                  artist: suggestion.artist,
                  title: suggestion.title,
                ),
                IconButton(
                  tooltip: 'Request it',
                  icon: const Icon(Icons.add_task_rounded),
                  onPressed: () => requestSong(
                    context,
                    artist: suggestion.artist,
                    title: suggestion.title,
                  ),
                ),
              ],
            ),
    );
  }
}
