import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/state/upload_queue.dart';

import 'upload_queue_test.dart' show FakeTransport;

void main() {
  test(
    'a folder scan started before logout cannot enqueue files afterward',
    () async {
      final dir = await Directory.systemTemp.createTemp('upload-account-scan-');
      final queue = UploadQueue(
        queueFile: File('${dir.path}/queue.json'),
        hashCacheFile: File('${dir.path}/hashes.json'),
      );
      try {
        await File('${dir.path}/private.mp3').writeAsString('private music');
        final scanning = queue.addFolder(dir.path);
        queue.attach(null);
        final next = FakeTransport();
        queue.attach(next);
        expect(await scanning, 0);
        await pumpEventQueue();
        expect(queue.items, isEmpty);
        expect(next.uploaded, isEmpty);
        await queue.save();
      } finally {
        queue.dispose();
        await dir.delete(recursive: true);
      }
    },
  );
}
