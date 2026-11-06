import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/state/download_manager.dart';

void main() {
  test('saved and in-progress downloads can be removed', () {
    expect(DownloadStatus.done.isSavedOrSaving, isTrue);
    expect(DownloadStatus.queued.isSavedOrSaving, isTrue);
    expect(DownloadStatus.downloading.isSavedOrSaving, isTrue);
  });

  test('a failed download is not saved, so it can be tried again', () {
    expect(DownloadStatus.failed.isSavedOrSaving, isFalse);
    expect(DownloadStatus.none.isSavedOrSaving, isFalse);
  });
}
