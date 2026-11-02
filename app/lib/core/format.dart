/// 3:05 or 1:02:09
String formatDuration(Duration duration) {
  final totalSeconds = duration.inSeconds < 0 ? 0 : duration.inSeconds;
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  final secondsText = seconds.toString().padLeft(2, '0');
  if (hours > 0)
    return '$hours:${minutes.toString().padLeft(2, '0')}:$secondsText';
  return '$minutes:$secondsText';
}

String greetingFor(DateTime now) {
  if (now.hour < 5) return 'Good night';
  if (now.hour < 12) return 'Good morning';
  if (now.hour < 18) return 'Good afternoon';
  return 'Good evening';
}

/// 12 KB, 340 MB, 1.2 GB
String formatBytes(int bytes) {
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
  if (bytes < 1024 * 1024 * 1024)
    return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}
