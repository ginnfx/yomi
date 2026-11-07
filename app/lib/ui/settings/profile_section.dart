import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/profile_controller.dart';
import '../../state/session.dart';
import '../../state/settings.dart';
import '../theme.dart';
import 'settings_widgets.dart';

/// The circular profile picture used on Home and in Settings.
class ProfileAvatar extends StatelessWidget {
  const ProfileAvatar({super.key, required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    final profile = context.watch<ProfileController>();
    final session = context.read<SessionController>();
    final file = profile.avatarFile;
    final name = profile.displayName(session.username);
    final initial = name.isEmpty ? '?' : name.characters.first.toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(shape: BoxShape.circle, color: context.accent),
      child: file != null
          ? Image.file(
              file,
              width: size,
              height: size,
              fit: BoxFit.cover,
              key: ValueKey(file.path),
              errorBuilder: (_, _, _) => Text(
                initial,
                style: yomiText(
                  size * 0.4,
                  weight: FontWeight.w800,
                  color: context.onAccent,
                ),
              ),
            )
          : Text(
              initial,
              style: yomiText(
                size * 0.4,
                weight: FontWeight.w800,
                color: context.onAccent,
              ),
            ),
    );
  }
}

class ProfileSection extends StatefulWidget {
  const ProfileSection({super.key});

  @override
  State<ProfileSection> createState() => _ProfileSectionState();
}

class _ProfileSectionState extends State<ProfileSection> {
  late final TextEditingController _nickname = TextEditingController(
    text: context.read<ProfileController>().nickname,
  );
  late final TextEditingController _bio = TextEditingController(
    text: context.read<ProfileController>().bio,
  );

  @override
  void dispose() {
    _nickname.dispose();
    _bio.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() =>
      _pickImage(context.read<ProfileController>().setAvatar);

  Future<void> _pickBanner() =>
      _pickImage(context.read<ProfileController>().setBanner);

  Future<void> _pickImage(Future<void> Function(File) use) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final picked = await FilePicker.pickFiles(type: FileType.image);
      final path = picked.isEmpty ? null : picked.first.path;
      if (path == null) return;
      await use(File(path));
    } on Object catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not use that photo: $error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = context.watch<ProfileController>();
    final session = context.read<SessionController>();
    return SettingsGroup(
      title: 'Profile',
      children: [
        Builder(
          builder: (context) {
            final settings = context.watch<SettingsController>();
            return SettingsSwitch(
              title: 'Share what I play with friends',
              subtitle:
                  'Also shows what friends who share are playing, on Home.',
              value: settings.shareListening,
              onChanged: settings.setShareListening,
            );
          },
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              GestureDetector(
                onTap: _pickPhoto,
                child: const ProfileAvatar(size: 72),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      profile.displayName(session.username),
                      style: yomiText(19, weight: FontWeight.w800),
                    ),
                    Text(
                      'Signed in as ${session.username}',
                      style: yomiText(
                        12.5,
                        weight: FontWeight.w500,
                        color: YomiColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        TextButton(
                          onPressed: _pickPhoto,
                          style: TextButton.styleFrom(
                            padding: EdgeInsets.zero,
                            minimumSize: const Size(0, 30),
                          ),
                          child: Text(
                            profile.avatarFile == null
                                ? 'Add photo'
                                : 'Change photo',
                          ),
                        ),
                        if (profile.avatarFile != null)
                          TextButton(
                            onPressed: profile.clearAvatar,
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.only(left: 14),
                              minimumSize: const Size(0, 30),
                            ),
                            child: const Text('Remove'),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TextField(
            controller: _nickname,
            textCapitalization: TextCapitalization.words,
            maxLength: 24,
            style: yomiText(15, weight: FontWeight.w600),
            decoration: const InputDecoration(
              labelText: 'Nickname',
              hintText: 'What should Yomi call you?',
              counterText: '',
            ),
            onChanged: profile.setNickname,
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TextField(
            controller: _bio,
            maxLength: kMaxBioLength,
            maxLines: 3,
            minLines: 1,
            style: yomiText(15, weight: FontWeight.w500),
            decoration: const InputDecoration(
              labelText: 'Bio',
              hintText: 'A line about you and your music',
            ),
            onChanged: profile.setBio,
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.image_outlined),
          title: Text(
            profile.bannerFile == null ? 'Add banner' : 'Change banner',
            style: yomiText(15, weight: FontWeight.w700),
          ),
          trailing: profile.bannerFile == null
              ? null
              : TextButton(
                  onPressed: profile.clearBanner,
                  child: const Text('Remove'),
                ),
          onTap: _pickBanner,
        ),
      ],
    );
  }
}
