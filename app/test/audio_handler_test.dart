import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:yomi/core/audio/yomi_audio_handler.dart';

class _Audio implements AudioPlayer {
  @override
  Stream<PlaybackEvent> get playbackEventStream => const Stream.empty();
  @override
  Stream<bool> get playingStream => const Stream.empty();
  @override
  Stream<SequenceState> get sequenceStateStream => const Stream.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Commands implements TransportCommands {
  final calls = <String>[];
  bool playing = false;

  @override
  bool get isPlaying => playing;
  @override
  Future<void> next() async => calls.add('next');
  @override
  Future<void> previous() async => calls.add('previous');
  @override
  Future<void> togglePlay() async => calls.add('toggle');
  @override
  Future<void> pause() async => calls.add('pause');
  @override
  Future<void> seek(Duration position) async => calls.add('seek');
}

void main() {
  late YomiAudioHandler handler;
  late _Commands commands;

  setUp(() {
    commands = _Commands();
    handler = YomiAudioHandler(_Audio())..commands = commands;
  });

  test('lock screen skips go through the app, not the player', () async {
    await handler.skipToNext();
    await handler.skipToPrevious();
    expect(commands.calls, ['next', 'previous']);
  });

  test('play only starts playback when it is stopped', () async {
    commands.playing = true;
    await handler.play();
    expect(commands.calls, isEmpty);
    commands.playing = false;
    await handler.play();
    expect(commands.calls, ['toggle']);
  });

  test('pause and seek are passed along', () async {
    await handler.pause();
    await handler.seek(const Duration(seconds: 5));
    expect(commands.calls, ['pause', 'seek']);
  });

  test('the notification shows pause while playing and play when stopped', () {
    PlaybackState state(bool isPlaying) => YomiAudioHandler.playbackStateFor(
      isPlaying: isPlaying,
      processing: ProcessingState.ready,
      position: Duration.zero,
      buffered: Duration.zero,
      speed: 1,
      index: 0,
    );
    expect(state(true).controls, contains(MediaControl.pause));
    expect(state(false).controls, contains(MediaControl.play));
    expect(state(true).controls.first, MediaControl.skipToPrevious);
    expect(state(true).controls.last, MediaControl.skipToNext);
  });
}
