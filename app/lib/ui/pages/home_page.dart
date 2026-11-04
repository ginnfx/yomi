import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../state/player_controller.dart';
import '../../state/profile_controller.dart';
import '../../state/session.dart';
import '../../state/settings.dart';
import '../settings/profile_section.dart';
import '../theme.dart';
import '../widgets/album_card.dart';
import '../widgets/async_section.dart';
import '../widgets/cover_art.dart';
import '../widgets/continue_listening.dart';
import '../widgets/compact_music_grid.dart';
import '../widgets/shimmer.dart';
import '../widgets/profile_panel.dart';
import '../widgets/song_tile.dart';
import 'collection_page.dart';

const int _shuffleBatch = 60;
const int _quickPickCount = 6;
const int _recentCount = 16;

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _refresh = 0;

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
    return SafeArea(
      bottom: false,
      child: RefreshIndicator(
        color: context.accent,
        backgroundColor: YomiColors.surfaceHigh,
        onRefresh: () async {
          setState(() => _refresh++);
          await Future<void>.delayed(const Duration(milliseconds: 500));
        },
        child: ListView(
          children: [
            _Header(name: profile.displayName(session.username)),
            const ContinueListening(),
            for (final id in sections) _section(id, session),
            if (sections.isEmpty)
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
    final client = session.client;
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
        return AsyncSection<List<_QuickPick>>(
          key: ValueKey('quick-$_refresh'),
          skeleton: const Padding(
            padding: EdgeInsets.only(top: 18),
            child: Shimmer(child: SkeletonBox(height: 190, radius: 16)),
          ),
          load: () async {
            final results = await Future.wait([
              client.playlists(),
              client.recentSongs(count: _quickPickCount),
            ]);
            final playlists = (results[0] as List<Playlist>)
                .take(3)
                .map(
                  (p) => _QuickPick(
                    p.name,
                    '${p.songCount} songs · Playlist',
                    p.coverArtId,
                    () => openPlaylist(context, p),
                  ),
                );
            final songs = results[1] as List<Song>;
            final recent = [
              for (var i = 0; i < songs.length; i++)
                _QuickPick(
                  songs[i].title,
                  songs[i].artist,
                  songs[i].coverArtId,
                  () => player.playQueue(songs, startIndex: i),
                ),
            ];
            return [
              ...playlists,
              ...recent,
            ].take(_quickPickCount).toList(growable: false);
          },
          builder: (context, picks) => picks.isEmpty
              ? const SizedBox.shrink()
              : Padding(
                  padding: const EdgeInsets.fromLTRB(
                    kPagePadding,
                    18,
                    kPagePadding,
                    0,
                  ),
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
                          children: [
                            for (final pick in picks) _QuickTile(pick: pick),
                          ],
                        ),
                ),
        );
      case 'recent':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionTitle('Recently added'),
            AsyncSection<List<Song>>(
              key: ValueKey('recent-$_refresh'),
              skeleton: const CardRowSkeleton(),
              load: () => client.recentSongs(count: _recentCount),
              builder: (context, songs) => songs.isEmpty
                  ? const _Empty('Nothing yet')
                  : CardRow(
                      children: [
                        for (var i = 0; i < songs.length; i++)
                          AlbumCard.song(
                            songs[i],
                            () => player.playQueue(songs, startIndex: i),
                          ),
                      ],
                    ),
            ),
          ],
        );
      case 'discover':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionTitle('Discover'),
            AsyncSection<List<Song>>(
              key: ValueKey('discover-$_refresh'),
              load: () => client.randomSongs(size: 8),
              builder: (context, songs) => Column(
                children: [
                  for (var i = 0; i < songs.length; i++)
                    SongTile(
                      song: songs[i],
                      onTap: () => player.playQueue(songs, startIndex: i),
                    ),
                ],
              ),
            ),
          ],
        );
    }
    return const SizedBox.shrink();
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
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
              greetingFor(DateTime.now()),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              semanticsLabel: '${greetingFor(DateTime.now())}, $name',
              style: yomiText(24, weight: FontWeight.w800, letterSpacing: -0.5),
            ),
          ),
        ],
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

class _Empty extends StatelessWidget {
  const _Empty(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: kPagePadding, vertical: 8),
    child: Text(
      message,
      style: yomiText(
        14,
        weight: FontWeight.w500,
        color: YomiColors.textSecondary,
      ),
    ),
  );
}
