import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

/// What the lock screen and notification can ask the app to do. Skips go through here
/// rather than straight to the player, so they get the same handling as in-app taps.
abstract interface class TransportCommands {
  Future<void> next();
  Future<void> previous();
  Future<void> togglePlay();
  Future<void> pause();
  Future<void> seek(Duration position);
  bool get isPlaying;
}

/// Connects the system's media controls to the app's player.
class YomiAudioHandler extends BaseAudioHandler with SeekHandler {
  YomiAudioHandler(this._player) {
    _player.playbackEventStream.listen(
      (_) => _publishState(),
      onError: (Object _, StackTrace _) => _publishState(),
    );
    _player.playingStream.listen((_) => _publishState());
    _player.sequenceStateStream.listen(_publishSong);
  }

  final AudioPlayer _player;
  TransportCommands? commands;

  void _publishSong(SequenceState state) {
    final tag = state.currentSource?.tag;
    if (tag is MediaItem) {
      mediaItem.add(tag.copyWith(duration: _player.duration ?? tag.duration));
    }
  }

  void _publishState() {
    playbackState.add(
      playbackStateFor(
        isPlaying: _player.playing,
        processing: _player.processingState,
        position: _player.position,
        buffered: _player.bufferedPosition,
        speed: _player.speed,
        index: _player.currentIndex,
      ),
    );
  }

  /// The state the system shows, kept separate so it can be tested without a real player.
  static PlaybackState playbackStateFor({
    required bool isPlaying,
    required ProcessingState processing,
    required Duration position,
    required Duration buffered,
    required double speed,
    required int? index,
  }) => PlaybackState(
    controls: [
      MediaControl.skipToPrevious,
      if (isPlaying) MediaControl.pause else MediaControl.play,
      MediaControl.skipToNext,
    ],
    systemActions: const {
      MediaAction.seek,
      MediaAction.seekForward,
      MediaAction.seekBackward,
    },
    androidCompactActionIndices: const [0, 1, 2],
    processingState: switch (processing) {
      // The player drops to idle on any stream error while it is still meant to be
      // playing. Reporting idle makes Android stop the playback service and release its
      // wake lock, so the retry would run in a process the system is free to suspend.
      ProcessingState.idle =>
        isPlaying ? AudioProcessingState.buffering : AudioProcessingState.idle,
      ProcessingState.loading => AudioProcessingState.loading,
      ProcessingState.buffering => AudioProcessingState.buffering,
      ProcessingState.ready => AudioProcessingState.ready,
      ProcessingState.completed => AudioProcessingState.completed,
    },
    playing: isPlaying,
    updatePosition: position,
    bufferedPosition: buffered,
    speed: speed,
    queueIndex: index,
  );

  @override
  Future<void> play() async {
    final app = commands;
    if (app == null || app.isPlaying) return;
    await app.togglePlay();
  }

  @override
  Future<void> pause() async => commands?.pause();

  @override
  Future<void> skipToNext() async => commands?.next();

  @override
  Future<void> skipToPrevious() async => commands?.previous();

  @override
  Future<void> seek(Duration position) async => commands?.seek(position);

  @override
  Future<void> stop() async {
    await commands?.pause();
    await super.stop();
  }
}
