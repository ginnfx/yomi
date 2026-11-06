import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/export/wanted_export.dart';

/// Opens the phone's share sheet with [file], so it can be saved to Files, sent to another
/// app, or put in cloud storage. Tells the person if it couldn't.
Future<void> shareExportedFile(
  BuildContext context,
  ExportedFile file, {
  Rect? origin,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final dir = await getTemporaryDirectory();
    final path = File('${dir.path}/${file.name}');
    await path.writeAsString(file.content, flush: true);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(path.path, mimeType: file.mimeType, name: file.name)],
        sharePositionOrigin: origin,
      ),
    );
  } on Object catch (error) {
    debugPrint('Could not share ${file.name}: $error');
    messenger.showSnackBar(
      const SnackBar(content: Text("Couldn't open sharing")),
    );
  }
}
