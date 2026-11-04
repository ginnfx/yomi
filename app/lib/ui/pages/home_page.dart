import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../state/home_controller.dart';
import '../../state/messages_controller.dart';
import '../../state/player_controller.dart';
import '../../state/profile_controller.dart';
import '../../state/session.dart';
import '../../state/settings.dart';
import '../settings/profile_section.dart';
import '../settings/home_layout_section.dart';
import '../theme.dart';
import '../widgets/album_card.dart';
import '../widgets/cover_art.dart';
import '../widgets/error_view.dart';
import '../widgets/continue_listening.dart';
import '../widgets/compact_music_grid.dart';
import '../widgets/shimmer.dart';
import '../widgets/profile_panel.dart';
import 'collection_page.dart';
import 'messages_page.dart';

const int _shuffleBatch = 60;
const int _quickPlaylistCount = 3;

class HomePage extends StatefulWidget {
  const HomePage({super.key, this.greetingTime});

  /// Fixes the greeting's time, for screenshots that shouldn't change by the hour.
  final DateTime? greetingTime;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  Future<void> _shuffleEverything() async {
    final player = context.read<PlayerController>();
    final client = context.read<SessionController>().client;
    HapticFeedback.mediumImpact();
    try {
      await player.playQueue(await client.randomSongs(size: _shuffleBatch));
    } on Exception catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionController>();
    final profile = context.watch<ProfileController>();
    final sections = context.watch<SettingsController>().visibleHomeSections;
    final home = context.watch<HomeController>();
    return SafeArea(
      bottom: false,
      child: RefreshIndicator(
        color: context.accent,
        backgroundColor: YomiColors.surfaceHigh,
        onRefresh: () async {
          await context.read<HomeController>().refresh();
        },
        child: ListView(
          children: [
            _Header(
              name: profile.displayName(session.username),
              greetingTime: widget.greetingTime,
            ),
            const ContinueListening(),
            for (final id in sections) _section(id, session),
            const _Shelves(),
            Center(
              child: TextButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const _EditHomePage(),
                  ),
                ),
                icon: const Icon(Icons.tune_rounded, size: 18),
                label: const Text('Edit Home'),
              ),
            ),
            if (sections.isEmpty && home.shelves.isEmpty && !home.isLoading)
              Padding(
                padding: const EdgeInsets.all(48),
                child: Text(
                  'Every section is hidden',
                  textAlign: TextAlign.center,
                  style: yomiText(
                    14,
                    weight: FontWeight.w500,
                    color: YomiColors.textSecondary,
                    height: 1.4,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _section(String id, SessionController session) {
    final isWide = context.isWideLayout;
    final player = context.read<PlayerController>();
    switch (id) {
      case 'shuffle':
        return Padding(
          padding: const EdgeInsets.fromLTRB(kPagePadding, 22, kPagePadding, 0),
          child: isWide
              ? Row(
                  children: [
                    Text(
                      'Made for your mood',
                      style: yomiText(16, weight: FontWeight.w700),
                    ),
                    const Spacer(),
                    FilledButton.tonalIcon(
                      onPressed: _shuffleEverything,
                      icon: const Icon(Icons.shuffle_rounded, size: 18),
                      label: const Text('Shuffle library'),
                    ),
                  ],
                )
              : _ShuffleHero(onTap: _shuffleEverything),
        );
      case 'quick':
        return _quickSection(isWide, player);
    }
    return const SizedBox.shrink();
  }

  Widget _quickSection(bool isWide, PlayerController player) {
    final home = context.watch<HomeController>();
    final songs = home.quickSongs;
    final picks = [
      for (final playlist in home.quickPlaylists.take(_quickPlaylistCount))
        _QuickPick(
          playlist.name,
          '${playlist.songCount} songs · Playlist',
          playlist.coverArtId,
          () => openPlaylist(context, playlist),
        ),
      for (var i = 0; i < songs.length; i++)
        _QuickPick(
          songs[i].title,
          songs[i].artist,
          songs[i].coverArtId,
          () => player.playQueue(songs, startIndex: i),
        ),
    ].take(quickPickCount).toList(growable: false);
    if (picks.isEmpty) {
      return home.isLoading
          ? const Padding(
              padding: EdgeInsets.only(top: 18),
              child: Shimmer(child: SkeletonBox(height: 190, radius: 16)),
            )
          : const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(kPagePadding, 18, kPagePadding, 0),
      child: isWide
          ? CompactMusicGrid(
              items: [
                for (final pick in picks)
                  MusicShortcut(
                    title: pick.title,
                    subtitle: pick.subtitle,
                    coverArtId: pick.coverArtId,
                    onTap: pick.onTap,
                  ),
              ],
            )
          : GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: YomiSpace.s,
              crossAxisSpacing: YomiSpace.s,
              childAspectRatio: 3.1,
              children: [for (final pick in picks) _QuickTile(pick: pick)],
            ),
    );
  }
}

class _EditHomePage extends StatelessWidget {
  const _EditHomePage();

  @override
  Widget build(BuildContext context) => PageBackground(
    child: Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text('Edit Home', style: yomiText(20, weight: FontWeight.w800)),
      ),
      body: const SingleChildScrollView(child: HomeLayoutSection()),
    ),
  );
}

/// The shelves that change with listening. See [HomeController].
class _Shelves extends StatelessWidget {
  const _Shelves();

  @override
  Widget build(BuildContext context) {
    final home = context.watch<HomeController>();
    final player = context.read<PlayerController>();
    final shelves = home.shelves;
    if (shelves.isEmpty) {
      if (home.isLoading) {
        return const Padding(
          padding: EdgeInsets.only(top: YomiSpace.xl),
          child: CardRowSkeleton(),
        );
      }
      final error = home.error;
      return error == null
          ? const SizedBox.shrink()
          : ErrorView(error: error, onRetry: home.refresh);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final shelf in shelves) ...[
          SectionTitle(shelf.title),
          CardRow(
            children: [
              for (var i = 0; i < shelf.songs.length; i++)
                AlbumCard.song(
                  shelf.songs[i],
                  () => player.playQueue(shelf.songs, startIndex: i),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.name, this.greetingTime});

  final String name;
  final DateTime? greetingTime;

  @override
  Widget build(BuildContext context) {
    final greeting = greetingFor(greetingTime ?? DateTime.now());
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        kPagePadding,
        YomiSpace.l,
        kPagePadding,
        0,
      ),
      child: Row(
        children: [
          if (!context.isWideLayout) ...[
            Semantics(
              button: true,
              label: 'Open profile',
              child: GestureDetector(
                onTap: () => openProfilePanel(context),
                child: const ProfileAvatar(size: 36),
              ),
            ),
            const SizedBox(width: YomiSpace.m),
          ],
          Expanded(
            child: Text(
              greeting,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              semanticsLabel: '$greeting, $name',
              style: yomiText(24, weight: FontWeight.w800, letterSpacing: -0.5),
            ),
          ),
          const _MessagesButton(),
        ],
      ),
    );
  }
}

class _MessagesButton extends StatelessWidget {
  const _MessagesButton();

  @override
  Widget build(BuildContext context) {
    final unread = context.select<MessagesController, int>(
      (messages) => messages.unreadTotal,
    );
    return IconButton(
      tooltip: unread > 0 ? 'Messages, $unread unread' : 'Messages',
      onPressed: () => openMessages(context),
      icon: Badge(
        isLabelVisible: unread > 0,
        backgroundColor: context.accent,
        textColor: Colors.black,
        label: Text('$unread'),
        child: const Icon(Icons.chat_bubble_outline_rounded),
      ),
    );
  }
}

class _QuickPick {
  const _QuickPick(this.title, this.subtitle, this.coverArtId, this.onTap);

  final String title;
  final String subtitle;
  final String? coverArtId;
  final VoidCallback onTap;
}

class _QuickTile extends StatelessWidget {
  const _QuickTile({required this.pick});

  final _QuickPick pick;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: YomiColors.surfaceHigh,
      borderRadius: BorderRadius.circular(YomiRadius.art),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          pick.onTap();
        },
        child: Row(
          children: [
            CoverArt(
              coverArtId: pick.coverArtId,
              size: 60,
              radius: 0,
              seed: pick.title,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                pick.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: yomiText(13.5, weight: FontWeight.w700, height: 1.2),
              ),
            ),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}

class _ShuffleHero extends StatelessWidget {
  const _ShuffleHero({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: FilledButton.icon(
        onPressed: onTap,
        icon: const Icon(Icons.shuffle_rounded, size: 18),
        label: const Text('Shuffle library'),
      ),
    );
  }
}
