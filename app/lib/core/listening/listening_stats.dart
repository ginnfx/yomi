import 'package:flutter/foundation.dart';

import '../search_index.dart';
import '../spotify/spotify_export.dart';
import 'history_api.dart';
import 'play_history.dart';

const int _maxTop = 50;
const int _hoursInDay = 24;

/// Which plays to count.
@immutable
class StatsRange {
  const StatsRange.all() : year = null, month = null;
  const StatsRange.year(int this.year) : month = null;
  const StatsRange.month(int this.year, int this.month);

  final int? year;
  final int? month;

  bool includes(DateTime at) =>
      (year == null || at.year == year) && (month == null || at.month == month);

  bool includesMonth(String yearMonth) {
    final parts = yearMonth.split('-');
    return (year == null || int.parse(parts[0]) == year) &&
        (month == null || int.parse(parts[1]) == month);
  }
}

@immutable
class TopSong {
  const TopSong(this.title, this.artist, this.plays);

  final String title;
  final String artist;
  final int plays;
}

@immutable
class TopItem {
  const TopItem(this.name, this.plays);

  final String name;
  final int plays;
}

/// The numbers behind the Stats screen and Wrapped.
@immutable
class ListeningStats {
  const ListeningStats({
    required this.plays,
    required this.minutes,
    required this.topSongs,
    required this.topArtists,
    required this.topGenres,
    required this.topMoods,
    required this.byHour,
    required this.currentStreak,
    required this.longestStreak,
    required this.activeDays,
  });

  final int plays;
  final int minutes;
  final List<TopSong> topSongs;
  final List<TopItem> topArtists;
  final List<TopItem> topGenres;
  final List<TopItem> topMoods;

  /// Plays in each hour of the day, 0 to 23.
  final List<int> byHour;
  final int currentStreak;
  final int longestStreak;
  final int activeDays;

  bool get isEmpty => plays == 0;

  /// The hour most played in, or null with no plays.
  int? get busiestHour {
    if (isEmpty) return null;
    var best = 0;
    for (var hour = 1; hour < byHour.length; hour++) {
      if (byHour[hour] > byHour[best]) best = hour;
    }
    return best;
  }
}

/// Works out the numbers for [range] from plays here and anything imported from Spotify.
/// Streaks only use plays here, as imported totals are by month rather than by day.
ListeningStats computeStats(
  List<ListenEvent> events, {
  required StatsRange range,
  required DateTime now,
  ImportedHistory? imported,
  List<String> Function(ListenEvent event)? moodsOf,
}) {
  final songs = <String, _SongCount>{};
  final artists = <String, _NameCount>{};
  final genres = <String, _NameCount>{};
  final moods = <String, _NameCount>{};
  final byHour = List<int>.filled(_hoursInDay, 0);
  final days = <int>{};
  var plays = 0;
  var seconds = 0;

  void countSong(String title, String artist, int count) {
    final key = '${normalizeForSearch(artist)}|${normalizeForSearch(title)}';
    (songs[key] ??= _SongCount(title, artist)).plays += count;
    if (artist.isNotEmpty) {
      (artists[normalizeForSearch(artist)] ??= _NameCount(artist)).plays +=
          count;
    }
  }

  for (final event in events) {
    if (event.kind != PlayKind.completed || !range.includes(event.at)) continue;
    plays++;
    seconds += event.seconds;
    byHour[event.at.hour]++;
    days.add(_dayNumber(event.at));
    countSong(event.title, event.artist, 1);
    final genre = event.genre;
    if (genre != null && genre.isNotEmpty) {
      (genres[normalizeForSearch(genre)] ??= _NameCount(genre)).plays++;
    }
    for (final mood in moodsOf?.call(event) ?? const <String>[]) {
      (moods[mood] ??= _NameCount(mood)).plays++;
    }
  }

  if (imported != null) {
    for (final month in imported.months.entries) {
      if (!range.includesMonth(month.key)) continue;
      for (final track in month.value.values) {
        plays += track.plays;
        seconds += track.ms ~/ Duration.millisecondsPerSecond;
        countSong(track.track, track.artist, track.plays);
      }
    }
    for (final year in imported.hours.entries) {
      if (range.year != null && year.key != range.year) continue;
      // Hours are kept by year, so a single month can't use them accurately.
      if (range.month != null) continue;
      for (var hour = 0; hour < _hoursInDay; hour++) {
        byHour[hour] += year.value[hour];
      }
    }
  }

  final (current, longest) = _streaks(days, _dayNumber(now));
  return ListeningStats(
    plays: plays,
    minutes: seconds ~/ Duration.secondsPerMinute,
    topSongs: List.unmodifiable(
      (songs.values.toList()..sort((a, b) => b.plays.compareTo(a.plays)))
          .take(_maxTop)
          .map((song) => TopSong(song.title, song.artist, song.plays)),
    ),
    topArtists: _ranked(artists),
    topGenres: _ranked(genres),
    topMoods: _ranked(moods),
    byHour: List.unmodifiable(byHour),
    currentStreak: current,
    longestStreak: longest,
    activeDays: days.length,
  );
}

List<TopItem> _ranked(Map<String, _NameCount> counts) => List.unmodifiable(
  (counts.values.toList()..sort((a, b) => b.plays.compareTo(a.plays)))
      .take(_maxTop)
      .map((item) => TopItem(item.name, item.plays)),
);

int _dayNumber(DateTime at) =>
    DateTime.utc(at.year, at.month, at.day).millisecondsSinceEpoch ~/
    Duration.millisecondsPerDay;

/// A streak still counts until today is over, so it doesn't look broken each morning.
(int, int) _streaks(Set<int> days, int today) {
  final sorted = days.toList()..sort();
  var longest = 0;
  var run = 0;
  int? previous;
  for (final day in sorted) {
    run = previous != null && day == previous + 1 ? run + 1 : 1;
    if (run > longest) longest = run;
    previous = day;
  }
  var current = 0;
  var day = days.contains(today) ? today : today - 1;
  while (days.contains(day)) {
    current++;
    day--;
  }
  return (current, longest);
}

class _SongCount {
  _SongCount(this.title, this.artist);

  final String title;
  final String artist;
  int plays = 0;
}

class _NameCount {
  _NameCount(this.name);

  final String name;
  int plays = 0;
}
