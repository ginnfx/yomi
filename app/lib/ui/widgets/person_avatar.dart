import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/messaging/messaging_api.dart';
import '../../state/messages_controller.dart';
import '../theme.dart';

/// A friend's picture, or their initial when they haven't set one.
class PersonAvatar extends StatelessWidget {
  const PersonAvatar({super.key, required this.profile, this.radius = 20});

  final ChatProfile profile;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final transport = context.read<MessagesController>().transport;
    final initial = profile.name.isEmpty
        ? '?'
        : profile.name.characters.first.toUpperCase();
    return CircleAvatar(
      radius: radius,
      backgroundColor: YomiColors.surfaceHigh,
      foregroundImage: profile.hasAvatar && transport != null
          ? NetworkImage(transport.avatarUri(profile.user).toString())
          : null,
      child: Text(
        initial,
        style: yomiText(radius * 0.8, weight: FontWeight.w700),
      ),
    );
  }
}
