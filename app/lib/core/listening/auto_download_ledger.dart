import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _prefsKey = 'autoDownloads.v1';

/// Which saved songs Yomi fetched by itself. Only these may ever be evicted;
/// anything the user saved by hand stays until the user removes it.
class AutoDownloadLedger {
  AutoDownloadLedger(this._prefs) {
    _load();
  }

  final SharedPreferences _prefs;
  Set<String> _auto = const {};
  Set<String> _declined = const {};
  Map<String, DateTime> _evictedAt = const {};

  Set<String> get autoIds => _auto;
  bool isAuto(String songId) => _auto.contains(songId);

  /// The user removed this song, so it is never fetched automatically again.
  bool isDeclined(String songId) => _declined.contains(songId);

  /// Plays before this moment don't count, so eviction can't immediately re-download.
  DateTime? evictedAt(String songId) => _evictedAt[songId];

  void markAuto(String songId) {
    _auto = {..._auto, songId};
    _evictedAt = _without(_evictedAt, songId);
    _save();
  }

  /// A song the user saved themselves is theirs from now on.
  void markManual(String songId) {
    _auto = {..._auto}..remove(songId);
    _declined = {..._declined}..remove(songId);
    _evictedAt = _without(_evictedAt, songId);
    _save();
  }

  void markUserRemoved(String songId) {
    if (!_auto.contains(songId)) return;
    _auto = {..._auto}..remove(songId);
    _declined = {..._declined, songId};
    _save();
  }

  void markEvicted(String songId, DateTime at) {
    _auto = {..._auto}..remove(songId);
    _evictedAt = {..._evictedAt, songId: at};
    _save();
  }

  static Map<String, DateTime> _without(
    Map<String, DateTime> map,
    String key,
  ) => {
    for (final entry in map.entries)
      if (entry.key != key) entry.key: entry.value,
  };

  void _load() {
    final raw = _prefs.getString(_prefsKey);
    if (raw == null) return;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      _auto = (json['auto'] as List<dynamic>).cast<String>().toSet();
      _declined = (json['declined'] as List<dynamic>).cast<String>().toSet();
      _evictedAt = {
        for (final entry in (json['evicted'] as Map<String, dynamic>).entries)
          entry.key: DateTime.fromMillisecondsSinceEpoch(
            (entry.value as num).toInt(),
          ),
      };
    } on Object catch (error) {
      // Treating everything as manual is the safe direction: nothing gets evicted.
      debugPrint('Ignoring unreadable auto-download list: $error');
    }
  }

  void _save() {
    _prefs.setString(
      _prefsKey,
      jsonEncode({
        'auto': _auto.toList(),
        'declined': _declined.toList(),
        'evicted': {
          for (final entry in _evictedAt.entries)
            entry.key: entry.value.millisecondsSinceEpoch,
        },
      }),
    );
  }
}
