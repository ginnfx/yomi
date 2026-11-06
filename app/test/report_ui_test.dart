import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomi/core/models.dart';
import 'package:yomi/core/reports/reports_api.dart';
import 'package:yomi/core/subsonic_client.dart';
import 'package:yomi/state/reports_controller.dart';
import 'package:yomi/ui/theme.dart';
import 'package:yomi/ui/widgets/report_sheet.dart';
import 'package:yomi/ui/widgets/reports_section.dart';

const _cleanSong = Song(
  id: 's1',
  title: 'Blue Hour',
  artist: 'Mira',
  album: 'Night Drive',
  durationSeconds: 200,
  explicitStatus: 'clean',
);

class _FakeServer {
  final posted = <Map<String, dynamic>>[];
  bool isAdmin = false;
  List<Map<String, dynamic>> reports = [];

  ReportsApi api() => ReportsApi(
    serverUrl: 'http://server',
    auth: SubsonicClient(
      baseUrl: 'http://server',
      username: 'u',
      password: 'p',
    ),
    port: 8443,
    httpClient: MockClient((request) async {
      if (request.method == 'GET') {
        return http.Response(
          jsonEncode({'reports': reports, 'isAdmin': isAdmin}),
          200,
        );
      }
      posted.add(jsonDecode(request.body) as Map<String, dynamic>);
      return http.Response('{}', 201);
    }),
  );
}

Map<String, dynamic> _report(
  String kind, {
  int count = 1,
  String status = 'open',
}) => {
  'id': '$kind$count$status',
  'kind': kind,
  'artist': 'Mira',
  'title': 'Blue Hour',
  'status': status,
  'count': count,
  'updatedMs': 1,
};

Future<ReportsController> _pump(
  WidgetTester tester,
  _FakeServer server,
  Widget Function(BuildContext context) body,
) async {
  SharedPreferences.setMockInitialValues({});
  final controller = ReportsController(await SharedPreferences.getInstance())
    ..attach(server.api());
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: controller,
      child: MaterialApp(
        theme: buildYomiTheme(accentPalettes.first),
        builder: (context, child) => YomiTheme(
          palette: accentPalettes.first,
          isTrueBlack: false,
          child: child!,
        ),
        home: Scaffold(body: Builder(builder: body)),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  testWidgets('a clean song starts on "I want explicit" and sends a note', (
    tester,
  ) async {
    // Arrange
    final server = _FakeServer();
    await _pump(
      tester,
      server,
      (context) => TextButton(
        onPressed: () => showReportSheet(context, _cleanSong),
        child: const Text('report'),
      ),
    );
    await tester.tap(find.text('report'));
    await tester.pumpAndSettle();

    // Act
    await tester.enterText(find.byType(TextField), 'the radio edit');
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();

    // Assert
    expect(server.posted.single['kind'], 'explicit_wanted');
    expect(server.posted.single['note'], 'the radio edit');
    expect(find.textContaining('list of things to fix'), findsOneWidget);
  });

  testWidgets('the admin sees open reports grouped by kind with counts', (
    tester,
  ) async {
    // Arrange
    final server = _FakeServer()
      ..isAdmin = true
      ..reports = [_report('cover_missing', count: 3), _report('missing_song')];

    // Act
    await _pump(tester, server, (_) => const ReportsSection());

    // Assert
    expect(find.text('Needs fixing'), findsOneWidget);
    expect(find.text('Cover missing · 1'), findsOneWidget);
    expect(find.text('Song to add · 1'), findsOneWidget);
    expect(find.textContaining('asked by 3'), findsOneWidget);
    expect(find.byTooltip('Actions'), findsNWidgets(2));
  });

  testWidgets('others see their own requests and how they ended', (
    tester,
  ) async {
    // Arrange
    final server = _FakeServer()
      ..reports = [_report('cover_wrong', status: 'resolved')];

    // Act
    await _pump(tester, server, (_) => const ReportsSection());

    // Assert
    expect(find.text('My requests'), findsOneWidget);
    expect(find.text('Fixed'), findsWidgets);
    expect(find.byTooltip('Actions'), findsNothing);
  });
}
