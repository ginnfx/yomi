import 'package:flutter/foundation.dart';

/// A group of songs to be named: their moods and a few of their artists.
@immutable
class MixRequest {
  const MixRequest({required this.moods, required this.artists});

  final List<String> moods;
  final List<String> artists;

  Map<String, Object?> toJson() => {'moods': moods, 'artists': artists};

  String get key => '${moods.join(',')}|${artists.join(',')}';
}

/// A name and a short line for a mix.
@immutable
class MixName {
  const MixName({required this.name, required this.description});

  factory MixName.fromJson(Map<String, dynamic> json) => MixName(
    name: (json['name'] as String?) ?? '',
    description: (json['description'] as String?) ?? '',
  );

  final String name;
  final String description;
}
