import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yomi/core/server_status.dart';
import 'package:yomi/state/dashboard_controller.dart';
import 'package:yomi/ui/pages/dashboard_page.dart';

import 'support/screen_harness.dart';

const _healthy = ServerStatus(
  isDetailed: true,
  uptime: Duration(days: 3, hours: 4),
  load: 1.25,
  memory: SpaceUsage(1000 * 1024 * 1024, 300 * 1024 * 1024),
  card: SpaceUsage(64 * 1024 * 1024 * 1024, 40 * 1024 * 1024 * 1024),
  internal: SpaceUsage(3800 * 1024 * 1024, 1100 * 1024 * 1024),
  battery: BatteryStatus(
    level: 94,
    isCharging: true,
    health: 'good',
    temperatureC: 31.5,
  ),
  isNavidromeHealthy: true,
  navidromeLatency: Duration(milliseconds: 80),
  songCount: 282,
  tailscale: 'Running',
  indexedSongs: 282,
);

Future<DashboardController> _controller({
  ServerStatus? status,
  Object? statusError,
  Object? pingError,
}) async {
  final controller = DashboardController(
    fetchStatus: () async {
      if (statusError != null) throw statusError;
      return status!;
    },
    ping: () async {
      if (pingError != null) throw pingError;
    },
  );
  await controller.refresh();
  return controller;
}

void main() {
  setUpAll(loadAppFonts);

  Widget page(DashboardController controller) =>
      ChangeNotifierProvider<DashboardController>.value(
        value: controller,
        child: const DashboardPage(routeLabel: 'Home network'),
      );

  test('parses the server report', () {
    final status = ServerStatus.fromJson(const {
      'detailed': true,
      'uptimeSeconds': 3600,
      'memory': {'total': 100, 'free': 25},
      'battery': {'level': 80, 'charging': false, 'stale': true},
      'navidrome': {'healthy': false, 'latencyMs': 5000},
      'tailscale': 'Running',
    });
    expect(status.uptime, const Duration(hours: 1));
    expect(status.memory!.usedShare, 0.75);
    expect(status.battery!.isStale, isTrue);
    expect(status.isNavidromeHealthy, isFalse);
  });

  test('missing or strange values become unknown, not zero', () {
    final status = ServerStatus.fromJson(const {
      'memory': {'total': 0, 'free': 0},
      'battery': 'nope',
    });
    expect(status.memory, isNull);
    expect(status.battery, isNull);
    expect(status.isDetailed, isFalse);
  });

  testWidgets('shows healthy details to an admin', (tester) async {
    final controller = await tester.runAsync(
      () => _controller(status: _healthy),
    );
    await pumpScreen(tester, page(controller!), size: phoneSize);
    expect(find.text('Everything is responding.'), findsOneWidget);
    expect(find.textContaining('94%'), findsOneWidget);
    expect(find.text('3 d 4 h'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a hung Navidrome is called out', (tester) async {
    final controller = await tester.runAsync(
      () => _controller(
        status: const ServerStatus(isDetailed: true, isNavidromeHealthy: false),
      ),
    );
    await pumpScreen(tester, page(controller!), size: phoneSize);
    expect(find.text('Music server not responding'), findsOneWidget);
  });

  testWidgets('others just see that it is online', (tester) async {
    final controller = await tester.runAsync(
      () => _controller(status: const ServerStatus()),
    );
    await pumpScreen(tester, page(controller!), size: phoneSize);
    expect(find.text('Online'), findsOneWidget);
    expect(find.text('Battery'), findsNothing);
    expect(find.textContaining('Only the server admin'), findsOneWidget);
  });

  testWidgets('says so when the server is unreachable', (tester) async {
    final controller = await tester.runAsync(
      () => _controller(
        statusError: const SocketException('down'),
        pingError: const SocketException('down'),
      ),
    );
    await pumpScreen(tester, page(controller!), size: phoneSize);
    expect(find.text('Offline'), findsOneWidget);
  });

  test('an old server is told apart from a dead one', () async {
    final old = await _controller(statusError: const StatusRouteMissing());
    expect(old.reachability, ServerReachability.needsUpdate);
    final dead = await _controller(
      statusError: const StatusRouteMissing(),
      pingError: const SocketException('down'),
    );
    expect(dead.reachability, ServerReachability.offline);
  });

  test('formats sizes and uptime', () {
    expect(formatBytes(1536 * 1024 * 1024), '1.5 GB');
    expect(formatBytes(500 * 1024 * 1024), '500 MB');
    expect(formatUptime(const Duration(minutes: 5)), '5 min');
    expect(formatUptime(const Duration(hours: 2, minutes: 5)), '2 h 5 min');
  });

  testWidgets('screenshot', (tester) async {
    final controller = await tester.runAsync(
      () => _controller(status: _healthy),
    );
    await pumpScreen(tester, page(controller!), size: phoneSize);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/dashboard_phone.png'),
    );
  }, skip: !Platform.isMacOS);
}
