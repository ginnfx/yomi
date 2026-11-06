import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:http/http.dart' as http;

import '../core/reports/reports_api.dart';
import '../core/search_index.dart';
import '../core/spotify/missing_songs.dart';

const String _requestedKey = 'reports.requestedMissing';

/// Most remembered missing-song requests, so the list can't grow forever.
const int _maxRemembered = 2000;

/// Song problems people reported: yours, or everyone's for the server admin.
class ReportsController extends ChangeNotifier {
  ReportsController(this._prefs);

  final SharedPreferences _prefs;
  ReportsApi? _api;
  List<SongReport> _reports = const [];
  bool _isAdmin = false;
  bool _isLoading = false;
  String? _error;
  int _generation = 0;
  List<WantedSong> _wanted = const [];
  bool _isWantedLoaded = false;

  List<SongReport> get reports => _reports;
  List<SongReport> get open => [
    for (final report in _reports)
      if (report.isOpen) report,
  ];

  /// What everyone has asked for, most wanted first.
  List<WantedSong> get wanted => _wanted;

  /// Whether [wanted] came from the server, as opposed to not having been asked yet.
  bool get isWantedLoaded => _isWantedLoaded;
  bool get isAdmin => _isAdmin;
  bool get isLoading => _isLoading;
  bool get isAvailable => _api != null;
  String? get error => _error;

  void attach(ReportsApi? api) {
    _generation++;
    _api = api;
    _reports = const [];
    _isAdmin = false;
    _error = null;
    _wanted = const [];
    _isWantedLoaded = false;
    notifyListeners();
  }

  Future<void> refreshWanted() async {
    final api = _api;
    if (api == null) return;
    final generation = _generation;
    try {
      final songs = await api.wanted();
      if (generation != _generation) return;
      _wanted = songs;
      _isWantedLoaded = true;
    } on Exception catch (error) {
      // A missing list isn't worth an error message; the section stays hidden.
      debugPrint('Could not load the wanted list: $error');
      return;
    }
    notifyListeners();
  }

  Future<void> refresh() async {
    final api = _api;
    if (api == null) return;
    final generation = _generation;
    _isLoading = true;
    notifyListeners();
    try {
      final page = await api.list();
      if (generation != _generation) return;
      _reports = List.unmodifiable(
        [...page.reports]..sort((a, b) {
          if (a.isOpen != b.isOpen) return a.isOpen ? -1 : 1;
          return b.updatedAt.compareTo(a.updatedAt);
        }),
      );
      _isAdmin = page.isAdmin;
      _error = null;
    } on Exception catch (error) {
      if (generation != _generation) return;
      debugPrint('Could not load reports: $error');
      _error = _describe(error);
    } finally {
      if (generation == _generation) {
        _isLoading = false;
        notifyListeners();
      }
    }
  }

  /// Sends a report. False, with [error] set, when the server didn't take it.
  Future<bool> report(ReportInput input) =>
      _act((api) => api.add(input), 'Could not send the report');

  Future<bool> close(
    SongReport report, {
    required bool isFixed,
    String note = '',
  }) => _act(
    (api) => api.close(report.id, isFixed: isFixed, note: note),
    'Could not update the report',
  );

  Future<bool> markAdded(SongReport report, String songId) => _act(
    (api) => api.markAdded(report.id, songId),
    'Could not update the request',
  );

  Future<bool> replace(SongReport report, {required String newSongId}) {
    final oldSongId = report.songId;
    if (oldSongId == null) return Future.value(false);
    return _act(
      (api) =>
          api.replace(report.id, oldSongId: oldSongId, newSongId: newSongId),
      'Could not replace the song',
    );
  }

  /// Closes open requests for a song someone just added to the library.
  Future<void> markAddedMatching(String artist, String title) async {
    final key = '${normalizeForSearch(artist)}|${normalizeForSearch(title)}';
    for (final report in open) {
      if (report.kind != ReportKind.missingSong) continue;
      final reportKey =
          '${normalizeForSearch(report.artist)}|${normalizeForSearch(report.title)}';
      if (reportKey == key) await markAdded(report, report.songId ?? '');
    }
  }

  /// Puts songs missing from imported playlists on the server's to-add list. Each song
  /// is sent once per device; the server merges requests from different people.
  Future<void> requestMissing(List<MissingSong> missing) async {
    final api = _api;
    if (api == null) return;
    final sent = (_prefs.getStringList(_requestedKey) ?? const []).toSet();
    final added = <String>[];
    for (final song in missing) {
      final key =
          '${normalizeForSearch(song.artist)}|${normalizeForSearch(song.title)}';
      if (sent.contains(key)) continue;
      try {
        await api.add(
          ReportInput(
            kind: ReportKind.missingSong,
            artist: song.artist,
            title: song.title,
            note: song.playlists.isEmpty ? '' : 'In ${song.playlists.first}',
          ),
        );
        added.add(key);
      } on Exception catch (error) {
        // The next launch tries the rest again.
        debugPrint('Could not request a missing song: $error');
        break;
      }
    }
    if (added.isEmpty) return;
    final remembered = [...sent, ...added];
    await _prefs.setStringList(
      _requestedKey,
      remembered.length > _maxRemembered
          ? remembered.sublist(remembered.length - _maxRemembered)
          : remembered,
    );
    await refresh();
  }

  Future<bool> _act(
    Future<void> Function(ReportsApi api) action,
    String fallback,
  ) async {
    final api = _api;
    if (api == null) {
      _error = 'Not connected to the server';
      notifyListeners();
      return false;
    }
    try {
      await action(api);
      _error = null;
    } on Exception catch (error) {
      debugPrint('$fallback: $error');
      _error = '$fallback. ${_describe(error)}';
      notifyListeners();
      return false;
    }
    await refresh();
    return true;
  }
}

/// The server's own words when it gave a reason, otherwise a plain explanation.
String _describe(Exception error) {
  if (error is http.ClientException && !error.message.contains('answered')) {
    return error.message;
  }
  if (error is TimeoutException) return 'The server took too long to answer.';
  return "The server couldn't take it right now.";
}
