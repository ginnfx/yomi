/// Enough work must be done, over enough time, before an estimate is believable.
const Duration kMinElapsedForEstimate = Duration(seconds: 8);

/// How long the rest will take if it goes as fast as what's done so far, or null
/// while it is too early (or nothing has finished) to say.
Duration? estimateTimeLeft({
  required int done,
  required int remaining,
  required Duration elapsed,
}) {
  if (done <= 0 || remaining <= 0 || elapsed < kMinElapsedForEstimate) {
    return null;
  }
  return Duration(
    milliseconds: (elapsed.inMilliseconds * remaining / done).round(),
  );
}

/// "about 2 min left", "less than a minute left"; empty when there is no estimate.
String describeTimeLeft(Duration? left) {
  if (left == null) return '';
  if (left < const Duration(seconds: 45)) return 'less than a minute left';
  final minutes = (left.inSeconds / 60).round();
  if (minutes < 60) return 'about $minutes min left';
  final hours = left.inMinutes ~/ 60;
  final rest = left.inMinutes % 60;
  return rest == 0 ? 'about $hours h left' : 'about $hours h $rest min left';
}
