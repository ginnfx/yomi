import 'dart:io';

import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

const MethodChannel _channel = MethodChannel('com.yomi.yomi/installer');

/// Hands a verified APK to Android's installer, which asks the user to confirm.
Future<void> launchApkInstaller(File apk) async {
  await _channel.invokeMethod<void>('installApk', {'path': apk.path});
}

Future<void> openReleasePage(Uri url) async {
  final isOpened = await launchUrl(url, mode: LaunchMode.externalApplication);
  if (!isOpened) throw Exception('No app could open $url');
}
