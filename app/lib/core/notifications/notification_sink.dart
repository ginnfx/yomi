import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Somewhere a notification can be shown. The real one talks to the system;
/// tests use one that records what it was asked to show.
abstract interface class NotificationSink {
  /// Prepares the sink; [onTap] gets the payload of a notification that was opened.
  Future<void> start({required ValueChanged<String> onTap});

  /// Asks the person to allow notifications, once the app has a reason to.
  Future<void> askPermission();

  Future<void> show({
    required int id,
    required String title,
    required String body,
    required String payload,
  });

  Future<void> cancelAll();
}

const String _channelId = 'messages';
const String _channelName = 'Messages';

/// Shows notifications through the system on Android, iOS, macOS and Linux.
class SystemNotificationSink implements NotificationSink {
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _isReady = false;

  @override
  Future<void> start({required ValueChanged<String> onTap}) async {
    try {
      const darwin = DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      );
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: darwin,
          macOS: darwin,
          linux: LinuxInitializationSettings(defaultActionName: 'Open'),
        ),
        onDidReceiveNotificationResponse: (response) {
          final payload = response.payload;
          if (payload != null && payload.isNotEmpty) onTap(payload);
        },
      );
      _isReady = true;
      // Opened from a notification while the app was closed.
      final launch = await _plugin.getNotificationAppLaunchDetails();
      final payload = launch?.notificationResponse?.payload;
      if (launch?.didNotificationLaunchApp == true &&
          payload != null &&
          payload.isNotEmpty) {
        onTap(payload);
      }
    } on Object catch (error) {
      debugPrint('Notifications are unavailable: $error');
    }
  }

  @override
  Future<void> askPermission() async {
    if (!_isReady) return;
    try {
      if (Platform.isAndroid) {
        await _plugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >()
            ?.requestNotificationsPermission();
      } else if (Platform.isIOS) {
        await _plugin
            .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin
            >()
            ?.requestPermissions(alert: true, badge: true, sound: true);
      } else if (Platform.isMacOS) {
        await _plugin
            .resolvePlatformSpecificImplementation<
              MacOSFlutterLocalNotificationsPlugin
            >()
            ?.requestPermissions(alert: true, badge: true, sound: true);
      }
    } on Object catch (error) {
      debugPrint('Could not ask for notification permission: $error');
    }
  }

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    required String payload,
  }) async {
    if (!_isReady) return;
    try {
      await _plugin.show(
        id: id,
        title: title,
        body: body,
        payload: payload,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription: 'New messages from friends',
            importance: Importance.high,
            priority: Priority.high,
            category: AndroidNotificationCategory.message,
          ),
          iOS: DarwinNotificationDetails(),
          macOS: DarwinNotificationDetails(),
          linux: LinuxNotificationDetails(),
        ),
      );
    } on Object catch (error) {
      debugPrint('Could not show a notification: $error');
    }
  }

  @override
  Future<void> cancelAll() async {
    if (!_isReady) return;
    try {
      await _plugin.cancelAll();
    } on Object catch (error) {
      debugPrint('Could not clear notifications: $error');
    }
  }
}
