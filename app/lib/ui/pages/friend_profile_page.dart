import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/ai/ai_api.dart';
import '../../core/messaging/messaging_api.dart';
import '../../core/mixes.dart';
import '../../core/models.dart';
import '../../state/ai_controller.dart';
import '../../state/catalog_controller.dart';
import '../../state/home_controller.dart';
import '../../state/messages_controller.dart';
import '../../state/player_controller.dart';
import '../../state/session.dart';
import '../theme.dart';
import '../../state/profile_controller.dart';
import '../settings/profile_section.dart';
import '../widgets/person_avatar.dart';
import '../widgets/profile_header.dart';
import 'collection_page.dart';
import 'messages_page.dart';
import 'playlist_preview_page.dart';

/// Opens someone's profile. Your own shows what friends see.
Future<void> openProfile(BuildContext context, String user) =>
    Navigator.of(context)
        .push(yomiRoute<void>(builder: (_) => FriendProfilePage(user: user)));

/// How many shared artists name a Blend.
const int _blendNameArtists = 3;

class FriendProfilePage extends StatefulWidget {
  const FriendProfilePage({super.key, required this.user});

  final String user;

  @override
  State<FriendProfilePage> createState() => _FriendProfilePageState();
}

class _FriendProfilePageState extends State<FriendProfilePage> {
  String get user => widget.user;

  @override
  void initState() {
    super.initState();
    // Their picture, banner and bio may have changed since the list was fetched.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<MessagesController>().refresh();
    });
  }

  @override
  Widget build(BuildContext context) {
    final messages = context.watch<MessagesController>();
    final me = context.read<SessionController>().username.toLowerCase();
    final isMe = user.toLowerCase() == me;
    final profile = messages.profileOf(user);
    final taste = context.watch<HomeController>().taste;
    final ai = context.read<AiController>();
    final library = context.read<CatalogController>().songs;
    final myArtists = topArtistsOf(taste);
    final myMoods = topMoodsOf(
      library: library,
      taste: taste,
      tagFor: ai.tagFor,
    );
    final shared = isMe
        ? SharedTaste(topArtists: myArtists, topMoods: myMoods)
        : profile.taste;
    final match = isMe || shared == null
        ? null
        : tasteMatch(
            myArtists: myArtists,
            theirArtists: shared.topArtists,
            myMoods: myMoods,
            theirMoods: shared.topMoods,
          );
    return Scaffold(
      appBar: AppBar(title: Text(isMe ? 'How friends see you' : profile.name)),
      body: ListView(
        padding: const EdgeInsets.all(
          kPagePadding,
        ).copyWith(bottom: kPagePadding + MediaQuery.paddingOf(context).bottom),
        children: [
          _header(context, profile, isMe),
          const SizedBox(height: 12),
          Center(
            child: Text(
              profile.name,
              style: yomiText(26, weight: FontWeight.w800),
            ),
          ),
          if (profile.bio.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                profile.bio,
                textAlign: TextAlign.center,
                style: yomiText(15, color: YomiColors.textSecondary),
              ),
            ),
          if (!isMe) ...[
            const SizedBox(height: 16),
            Center(
              child: FilledButton.tonalIcon(
                onPressed: () => Navigator.of(
                  context,
                ).push(yomiRoute<void>(builder: (_) => ThreadPage(user: user))),
                icon: const Icon(Icons.chat_bubble_outline_rounded),
                label: const Text('Message'),
              ),
            ),
          ],
          if (profile.nowPlaying case final playing?)
            _NowPlayingCard(playing: playing),
          if (match != null) _MatchCard(percent: match, name: profile.name),
          if (shared != null && shared.topArtists.isNotEmpty) ...[
            _Heading(isMe ? 'Your top artists' : 'Top artists'),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final artist in shared.topArtists)
                  ActionChip(
                    label: Text(artist),
                    onPressed: () => _openArtist(context, artist),
                  ),
              ],
            ),
          ],
          if (shared != null && shared.topMoods.isNotEmpty) ...[
            _Heading(isMe ? 'Your moods' : 'Their moods'),
            Wrap(
              spacing: 8,
              children: [
                for (final mood in shared.topMoods) Chip(label: Text(mood)),
              ],
            ),
          ],
          if (!isMe && shared != null && shared.topArtists.isNotEmpty) ...[
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => _openBlend(context, profile, shared),
              icon: const Icon(Icons.join_inner_rounded),
              label: Text('Make a Blend with ${profile.name}'),
            ),
          ],
          if (shared == null)
            Padding(
              padding: const EdgeInsets.only(top: 24),
              child: Text(
                isMe
                    ? 'Play a few songs and your taste shows up here.'
                    : "${profile.name} isn't sharing their taste yet.",
                textAlign: TextAlign.center,
                style: yomiText(14, color: YomiColors.textSecondary),
              ),
            ),
          if (isMe)
            Padding(
              padding: const EdgeInsets.only(top: 24),
              child: Text(
                'Friends see your top artists and moods, never single plays. '
                "Turn off sharing what you're listening to in Settings to "
                'hide them.',
                style: yomiText(12.5, color: YomiColors.textSecondary),
              ),
            ),
        ],
      ),
    );
  }

  void _openArtist(BuildContext context, String artist) {
    final songs = [
      for (final song in context.read<CatalogController>().songs)
        if (song.artist == artist) song,
    ];
    Navigator.of(context).push(
      yomiRoute<void>(
        builder: (_) => CollectionPage(
          title: artist,
          subtitle: '${songs.length} songs',
          savedSongs: songs,
          loadSongs: () async => songs,
        ),
      ),
    );
  }

  Future<void> _openBlend(
    BuildContext context,
    ChatProfile friend,
    SharedTaste theirs,
  ) async {
    final ai = context.read<AiController>();
    final mine = context.read<HomeController>().taste;
    final library = context.read<CatalogController>().songs;
    final songs = blendSongs(
      library: library,
      mine: mine,
      theirArtists: theirs.topArtists,
      random: Random(),
    );
    final myArtists = topArtistsOf(mine).toSet();
    final both = [
      for (final artist in theirs.topArtists)
        if (myArtists.contains(artist)) artist,
    ];
    final request = MixRequest(
      moods: theirs.topMoods.take(2).toList(),
      artists: (both.isEmpty ? theirs.topArtists : both)
          .take(_blendNameArtists)
          .toList(),
    );
    final named = (await ai.nameMixes([request]))[request.key];
    if (!context.mounted) return;
    await openPlaylistPreview(
      context,
      name: named?.name ?? 'You + ${friend.name}',
      description:
          named?.description ?? 'A blend of your taste and ${friend.name}’s',
      songs: songs,
    );
  }

  Widget _header(BuildContext context, ChatProfile profile, bool isMe) {
    final transport = context.read<MessagesController>().transport;
    final ownBanner = isMe
        ? context.watch<ProfileController>().bannerFile
        : null;
    final ImageProvider? banner = ownBanner != null
        ? FileImage(ownBanner)
        : profile.hasBanner && transport != null
        ? NetworkImage(
            transport
                .bannerUri(profile.user, version: profile.bannerVersion)
                .toString(),
          )
        : null;
    const radius = kProfileAvatarSize / 2;
    return Column(
      children: [
        ProfileHeader(
          banner: banner,
          alignment: Alignment.center,
          avatar: isMe
              ? const ProfileAvatar(size: kProfileAvatarSize)
              : PersonAvatar(profile: profile, radius: radius),
        ),
        const SizedBox(height: kProfileAvatarSize / 2),
      ],
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 8),
    child: Text(text, style: yomiText(16, weight: FontWeight.w800)),
  );
}

class _MatchCard extends StatelessWidget {
  const _MatchCard({required this.percent, required this.name});

  final int percent;
  final String name;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 20),
    child: Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: YomiColors.surfaceHigh,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: percent / 100),
            duration: const Duration(milliseconds: 900),
            curve: Curves.easeOutCubic,
            builder: (context, value, _) => SizedBox.square(
              dimension: 56,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  CircularProgressIndicator(
                    value: value,
                    strokeWidth: 6,
                    color: context.accent,
                    backgroundColor: YomiColors.surface,
                  ),
                  Text(
                    '${(value * 100).round()}%',
                    style: yomiText(14, weight: FontWeight.w800),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              percent >= 60
                  ? 'You and $name have very similar taste'
                  : percent >= 25
                  ? 'You and $name share some favourites'
                  : 'You and $name listen to quite different things',
              style: yomiText(15, weight: FontWeight.w700),
            ),
          ),
        ],
      ),
    ),
  );
}

class _NowPlayingCard extends StatelessWidget {
  const _NowPlayingCard({required this.playing});

  final FriendPlaying playing;

  @override
  Widget build(BuildContext context) {
    Song? song;
    for (final candidate in context.read<CatalogController>().songs) {
      if (candidate.id == playing.songId) {
        song = candidate;
        break;
      }
    }
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: ListTile(
        tileColor: YomiColors.surfaceHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        leading: Icon(Icons.graphic_eq_rounded, color: context.accent),
        title: Text(
          playing.title ?? 'Listening now',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: yomiText(15, weight: FontWeight.w700),
        ),
        subtitle: Text('Listening now · ${playing.artist ?? ''}'),
        trailing: song == null ? null : const Icon(Icons.play_arrow_rounded),
        onTap: song == null
            ? null
            : () => context.read<PlayerController>().playQueue([song!]),
      ),
    );
  }
}
