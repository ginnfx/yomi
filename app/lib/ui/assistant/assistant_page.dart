import 'dart:math' as math;

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
import 'yomi_avatar.dart';

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
  final _composerFocus = FocusNode();

  /// Answers that were already there when the page opened appear at once; only
  /// ones that arrive while you watch are typed out.
  late final Set<ChatTurn> _alreadyShown = {
    ...context.read<AssistantController>().turns,
  };

  bool get _reduceMotion =>
      MediaQuery.disableAnimationsOf(context) ||
      context.motion(YomiMotion.standard) == Duration.zero;

  void _followConversation({bool force = false}) {
    if (!force && _scroll.hasClients && _scroll.position.extentAfter > 120) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      if (_reduceMotion) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      } else {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 360),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  @override
  void dispose() {
    _composerFocus.dispose();
    _question.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _ask(String text) async {
    final assistant = context.read<AssistantController>();
    if (text.trim().isEmpty || assistant.isThinking || !assistant.isAvailable) {
      return;
    }
    _question.clear();
    final request = assistant.ask(text);
    _followConversation(force: true);
    await request;
    if (!mounted) return;
    _followConversation();
  }

  @override
  Widget build(BuildContext context) {
    final assistant = context.watch<AssistantController>();
    return PageBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: _Title(isThinking: assistant.isThinking),
          actions: [
            if (assistant.turns.isNotEmpty)
              IconButton(
                tooltip: 'Start over',
                icon: const Icon(Icons.refresh_rounded),
                onPressed: assistant.isThinking ? null : assistant.clear,
              ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: AnimatedSwitcher(
                duration: _reduceMotion
                    ? Duration.zero
                    : const Duration(milliseconds: 240),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                child: assistant.turns.isEmpty
                    ? _Starters(key: const ValueKey('starters'), onPicked: _ask)
                    : ListView(
                        key: const ValueKey('conversation'),
                        controller: _scroll,
                        padding: const EdgeInsets.all(kPagePadding),
                        children: [
                          for (final turn in assistant.turns)
                            _MessageEntrance(
                              key: ObjectKey(turn),
                              fromRight: turn.isUser,
                              child: turn.isUser
                                  ? _Question(text: turn.text)
                                  : _Answer(
                                      answer: turn.answer!,
                                      isFresh: !_alreadyShown.contains(turn),
                                    ),
                            ),
                          AnimatedSwitcher(
                            duration: _reduceMotion
                                ? Duration.zero
                                : const Duration(milliseconds: 180),
                            child: assistant.isThinking
                                ? const _Thinking()
                                : const SizedBox.shrink(),
                          ),
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
                child: ListenableBuilder(
                  listenable: _composerFocus,
                  builder: (context, _) => AnimatedContainer(
                    duration: _reduceMotion
                        ? Duration.zero
                        : const Duration(milliseconds: 200),
                    curve: Curves.easeOutCubic,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(YomiRadius.sheet),
                      border: Border.all(
                        color: context.accent.withValues(
                          alpha: _composerFocus.hasFocus ? 0.55 : 0.0,
                        ),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: context.accent.withValues(
                            alpha: _composerFocus.hasFocus ? 0.08 : 0,
                          ),
                          blurRadius: 18,
                        ),
                      ],
                    ),
                    child: TextField(
                      controller: _question,
                      focusNode: _composerFocus,
                      enabled: !assistant.isThinking,
                      maxLength: 500,
                      textInputAction: TextInputAction.send,
                      onSubmitted: _ask,
                      decoration: InputDecoration(
                        counterText: '',
                        hintText: 'Ask for music in your own words',
                        suffixIcon: ValueListenableBuilder<TextEditingValue>(
                          valueListenable: _question,
                          builder: (context, value, _) {
                            final canSend =
                                value.text.trim().isNotEmpty &&
                                !assistant.isThinking;
                            return AnimatedScale(
                              scale: canSend ? 1 : 0.9,
                              duration: _reduceMotion
                                  ? Duration.zero
                                  : const Duration(milliseconds: 180),
                              child: IconButton(
                                tooltip: 'Ask',
                                icon: AnimatedSwitcher(
                                  duration: _reduceMotion
                                      ? Duration.zero
                                      : const Duration(milliseconds: 180),
                                  child: Icon(
                                    assistant.isThinking
                                        ? Icons.more_horiz_rounded
                                        : Icons.send_rounded,
                                    key: ValueKey(assistant.isThinking),
                                    color: canSend
                                        ? context.accent
                                        : YomiColors.textSecondary,
                                  ),
                                ),
                                onPressed: canSend
                                    ? () => _ask(_question.text)
                                    : null,
                              ),
                            );
                          },
                        ),
                      ),
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
  const _Starters({super.key, required this.onPicked});

  final ValueChanged<String> onPicked;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(kPagePadding),
    children: [
      const SizedBox(height: YomiSpace.xl),
      const Center(child: YomiAvatar(size: 96)),
      const SizedBox(height: YomiSpace.l),
      Text(
        'What do you feel like hearing?',
        textAlign: TextAlign.center,
        style: yomiText(22, weight: FontWeight.w800),
      ),
      const SizedBox(height: YomiSpace.xs),
      Text(
        'Ask in your own words and Yomi will find it.',
        textAlign: TextAlign.center,
        style: yomiText(
          14,
          weight: FontWeight.w500,
          color: YomiColors.textSecondary,
        ),
      ),
      const SizedBox(height: YomiSpace.xl),
      Wrap(
        alignment: WrapAlignment.center,
        spacing: YomiSpace.s,
        runSpacing: YomiSpace.s,
        children: [
          for (var i = 0; i < _starters.length; i++)
            _Staggered(
              index: i,
              child: ActionChip(
                label: Text(_starters[i]),
                onPressed: () => onPicked(_starters[i]),
              ),
            ),
        ],
      ),
    ],
  );
}

/// The assistant's name with its picture and what it is doing.
class _Title extends StatelessWidget {
  const _Title({required this.isThinking});

  final bool isThinking;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      YomiAvatar(size: 34, isThinking: isThinking),
      const SizedBox(width: YomiSpace.m),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Ask Yomi', style: yomiText(18, weight: FontWeight.w800)),
          AnimatedSwitcher(
            duration: context.motion(YomiMotion.standard),
            child: Text(
              isThinking ? 'Thinking…' : 'Your music assistant',
              key: ValueKey(isThinking),
              style: yomiText(
                11.5,
                weight: FontWeight.w500,
                color: isThinking ? context.accent : YomiColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    ],
  );
}

/// Fades and rises into place, each item a little after the one before it.
class _Staggered extends StatelessWidget {
  const _Staggered({required this.index, required this.child});

  final int index;
  final Widget child;

  static const Duration _step = Duration(milliseconds: 70);
  static const Duration _each = Duration(milliseconds: 360);

  @override
  Widget build(BuildContext context) {
    final isReduced =
        MediaQuery.disableAnimationsOf(context) ||
        context.motion(YomiMotion.standard) == Duration.zero;
    if (isReduced) return child;
    final delay = _step * index;
    final total = delay + _each;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: total,
      curve: Interval(
        delay.inMilliseconds / total.inMilliseconds,
        1,
        curve: Curves.easeOutCubic,
      ),
      child: child,
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, 12 * (1 - value)),
          child: child,
        ),
      ),
    );
  }
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
        style: yomiText(15, weight: FontWeight.w600, color: context.onAccent),
      ),
    ),
  );
}

/// Stable keys keep existing turns from animating again as new turns arrive.
class _MessageEntrance extends StatelessWidget {
  const _MessageEntrance({
    super.key,
    required this.child,
    this.fromRight = false,
  });
  final Widget child;
  final bool fromRight;

  @override
  Widget build(BuildContext context) {
    final reduced =
        MediaQuery.disableAnimationsOf(context) ||
        context.motion(YomiMotion.standard) == Duration.zero;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: reduced ? 1 : 0, end: 1),
      duration: reduced ? Duration.zero : const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      child: child,
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(
            (fromRight ? 14 : -14) * (1 - value),
            10 * (1 - value),
          ),
          child: Transform.scale(
            scale: 0.96 + 0.04 * value,
            alignment: fromRight ? Alignment.centerRight : Alignment.centerLeft,
            child: child,
          ),
        ),
      ),
    );
  }
}

class _Thinking extends StatefulWidget {
  const _Thinking();

  @override
  State<_Thinking> createState() => _ThinkingState();
}

class _ThinkingState extends State<_Thinking>
    with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context) ||
        context.motion(YomiMotion.standard) == Duration.zero) {
      _pulse.stop();
      _pulse.value = 0;
    } else {
      _pulse.repeat();
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Yomi is thinking',
    liveRegion: true,
    child: ExcludeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: YomiSpace.m),
        child: Row(
          children: [
            const YomiAvatar(size: 28, isThinking: true),
            const SizedBox(width: YomiSpace.m),
            AnimatedBuilder(
              animation: _pulse,
              builder: (context, _) => Row(
                mainAxisSize: MainAxisSize.min,
                children: List.generate(3, (index) {
                  final wave =
                      (math.sin(_pulse.value * 2 * math.pi - index * 0.8) + 1) /
                      2;
                  return Transform.translate(
                    offset: Offset(0, -3 * wave),
                    child: Container(
                      width: 5,
                      height: 5,
                      margin: const EdgeInsets.only(right: 4),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: context.accent.withValues(
                          alpha: 0.35 + 0.65 * wave,
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _Answer extends StatelessWidget {
  const _Answer({required this.answer, this.isFresh = false});

  final ChatAnswer answer;

  /// Typed out as it appears, instead of showing at once.
  final bool isFresh;

  @override
  Widget build(BuildContext context) {
    final library = answer.librarySongs;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: YomiSpace.s),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const YomiAvatar(size: 30),
          const SizedBox(width: YomiSpace.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (answer.reply.isNotEmpty)
                  _TypedText(
                    answer.reply,
                    animate: isFresh,
                    style: yomiText(15, weight: FontWeight.w500, height: 1.35),
                  ),
                if (library.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: YomiSpace.s),
                    child: _Staggered(
                      index: isFresh ? 2 : 0,
                      child: Wrap(
                        spacing: YomiSpace.s,
                        children: [
                          FilledButton.icon(
                            onPressed: () => context
                                .read<PlayerController>()
                                .playQueue(library),
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
                  ),
                for (var i = 0; i < answer.songs.length; i++)
                  _MessageEntrance(
                    key: ValueKey(
                      '${answer.songs[i].artist}/${answer.songs[i].title}',
                    ),
                    child: _Staggered(
                      index: isFresh ? i + 3 : 0,
                      child: _SuggestionRow(suggestion: answer.songs[i]),
                    ),
                  ),
              ],
            ),
          ),
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

/// Reveals text word by word, quickly, so a reply feels like it is being said.
class _TypedText extends StatelessWidget {
  const _TypedText(this.text, {required this.animate, required this.style});

  final String text;
  final bool animate;
  final TextStyle style;

  static const Duration _perWord = Duration(milliseconds: 28);
  static const Duration _longest = Duration(milliseconds: 1600);

  @override
  Widget build(BuildContext context) {
    final isReduced =
        MediaQuery.disableAnimationsOf(context) ||
        context.motion(YomiMotion.standard) == Duration.zero;
    if (!animate || isReduced) return Text(text, style: style);
    final words = text.split(' ');
    final duration = _perWord * words.length > _longest
        ? _longest
        : _perWord * words.length;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: duration,
      builder: (context, value, _) {
        final shown = (words.length * value).ceil().clamp(1, words.length);
        // The full text is laid out invisibly, so the bubble never changes size.
        return Stack(
          children: [
            Opacity(opacity: 0, child: Text(text, style: style)),
            Text(words.take(shown).join(' '), style: style),
          ],
        );
      },
    );
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
