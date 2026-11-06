import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/messaging/messaging_api.dart';
import '../../core/models.dart';
import '../../core/song_share.dart';
import '../../state/messages_controller.dart';
import '../../state/session.dart';
import '../theme.dart';
import '../widgets/cover_color.dart';
import '../widgets/person_avatar.dart';
import '../widgets/send_to_sheet.dart';
import 'share_card.dart';

const double _imageScale = 3;
const Color _noColourYet = Color(0xFF3A3A3A);

/// Spotify's share sheet: a card to share as a picture, friends on Yomi to send it to,
/// and the phone's own apps (WhatsApp, Instagram, Messages…) for everyone else.
Future<void> showShareSong(BuildContext context, Song song) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _ShareSongSheet(song: song),
    );

class _ShareSongSheet extends StatefulWidget {
  const _ShareSongSheet({required this.song});

  final Song song;

  @override
  State<_ShareSongSheet> createState() => _ShareSongSheetState();
}

class _ShareSongSheetState extends State<_ShareSongSheet> {
  final _card = GlobalKey();
  ShareCardStyle _style = ShareCardStyle.cover;
  bool _isBusy = false;

  Song get _song => widget.song;

  Rect? _originOf(BuildContext buttonContext) {
    final box = buttonContext.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  Future<XFile> _cardImage() async {
    final boundary =
        _card.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: _imageScale);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/yomi-song-${_song.id}.png');
    await file.writeAsBytes(data!.buffer.asUint8List());
    return XFile(file.path, mimeType: 'image/png');
  }

  Future<void> _shareImage(BuildContext buttonContext) async {
    final messenger = ScaffoldMessenger.of(context);
    final origin = _originOf(buttonContext);
    setState(() => _isBusy = true);
    try {
      await SharePlus.instance.share(
        ShareParams(
          files: [await _cardImage()],
          text: songShareText(_song),
          sharePositionOrigin: origin,
        ),
      );
    } on Object catch (error) {
      debugPrint('Could not share ${_song.id} as a picture: $error');
      messenger.showSnackBar(
        const SnackBar(content: Text("Couldn't make the picture to share")),
      );
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _shareText(BuildContext buttonContext) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await SharePlus.instance.share(
        ShareParams(
          text: songShareText(_song),
          sharePositionOrigin: _originOf(buttonContext),
        ),
      );
    } on Object catch (error) {
      debugPrint('Could not share ${_song.id}: $error');
      messenger.showSnackBar(
        const SnackBar(content: Text("Couldn't open sharing")),
      );
    }
  }

  Future<void> _copy() async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: songShareText(_song)));
    messenger.showSnackBar(const SnackBar(content: Text('Copied')));
  }

  Future<void> _sendTo(ChatProfile person) async {
    final messenger = ScaffoldMessenger.of(context);
    final messages = context.read<MessagesController>();
    Navigator.pop(context);
    final isSent = await messages.sendTo(
      person.user,
      songId: _song.id,
      songTitle: '${_song.title} · ${_song.artist}',
    );
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          isSent
              ? 'Sent to ${person.name}'
              : messages.error ?? "Couldn't send that",
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final people = sendCandidates(
      context.read<MessagesController>(),
      context.read<SessionController>().username,
    );
    return CoverColorBuilder(
      coverArtId: _song.coverArtId,
      builder: (context, found) {
        final color = found ?? _noColourYet;
        return SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RepaintBoundary(
                key: _card,
                child: ShareCard(song: _song, style: _style, color: color),
              ),
              const SizedBox(height: YomiSpace.l),
              _StylePicker(
                color: color,
                selected: _style,
                onChanged: (style) => setState(() => _style = style),
              ),
              const SizedBox(height: YomiSpace.l),
              if (people.isNotEmpty) ...[
                Divider(height: 1, color: YomiColors.faint(0.10)),
                _PeopleRow(people: people, onTap: _sendTo),
              ],
              Divider(height: 1, color: YomiColors.faint(0.10)),
              _AppsRow(
                isBusy: _isBusy,
                onCopy: _copy,
                onShareImage: _shareImage,
                onShareText: _shareText,
              ),
              const SizedBox(height: YomiSpace.l),
            ],
          ),
        );
      },
    );
  }
}

class _StylePicker extends StatelessWidget {
  const _StylePicker({
    required this.color,
    required this.selected,
    required this.onChanged,
  });

  final Color color;
  final ShareCardStyle selected;
  final ValueChanged<ShareCardStyle> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (final style in ShareCardStyle.values)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Semantics(
              button: true,
              selected: style == selected,
              label: switch (style) {
                ShareCardStyle.cover => 'Cover colour',
                ShareCardStyle.fade => 'Fade',
                ShareCardStyle.black => 'Black',
              },
              child: GestureDetector(
                onTap: () => onChanged(style),
                child: AnimatedContainer(
                  duration: context.motion(YomiMotion.quick),
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: shareCardBackground(style, color),
                    border: Border.all(
                      color: style == selected
                          ? YomiColors.textPrimary
                          : YomiColors.faint(0.2),
                      width: style == selected ? 3 : 1,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _PeopleRow extends StatelessWidget {
  const _PeopleRow({required this.people, required this.onTap});

  final List<ChatProfile> people;
  final ValueChanged<ChatProfile> onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 112,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
          horizontal: YomiSpace.m,
          vertical: YomiSpace.m,
        ),
        itemCount: people.length,
        itemBuilder: (context, i) => _RoundChoice(
          label: people[i].name,
          onTap: () => onTap(people[i]),
          child: PersonAvatar(profile: people[i], radius: 28),
        ),
      ),
    );
  }
}

class _AppsRow extends StatelessWidget {
  const _AppsRow({
    required this.isBusy,
    required this.onCopy,
    required this.onShareImage,
    required this.onShareText,
  });

  final bool isBusy;
  final VoidCallback onCopy;
  final ValueChanged<BuildContext> onShareImage;
  final ValueChanged<BuildContext> onShareText;

  Widget _icon(IconData icon) => CircleAvatar(
    radius: 28,
    backgroundColor: YomiColors.surfaceHigh,
    child: Icon(icon, color: YomiColors.textPrimary),
  );

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 112,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
          horizontal: YomiSpace.m,
          vertical: YomiSpace.m,
        ),
        children: [
          _RoundChoice(
            label: 'Copy',
            onTap: onCopy,
            child: _icon(Icons.link_rounded),
          ),
          Builder(
            builder: (button) => _RoundChoice(
              label: 'Picture',
              onTap: isBusy ? null : () => onShareImage(button),
              child: isBusy
                  ? const SizedBox(
                      width: 56,
                      height: 56,
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      ),
                    )
                  : _icon(Icons.image_outlined),
            ),
          ),
          Builder(
            builder: (button) => _RoundChoice(
              label: 'More',
              onTap: () => onShareText(button),
              child: _icon(Icons.ios_share_rounded),
            ),
          ),
        ],
      ),
    );
  }
}

class _RoundChoice extends StatelessWidget {
  const _RoundChoice({
    required this.label,
    required this.onTap,
    required this.child,
  });

  final String label;
  final VoidCallback? onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(YomiRadius.card),
      onTap: onTap,
      child: SizedBox(
        width: 80,
        child: Column(
          children: [
            child,
            const SizedBox(height: 6),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: yomiText(12.5, weight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}
