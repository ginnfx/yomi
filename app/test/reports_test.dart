import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomi/core/models.dart';
import 'package:yomi/core/reports/reports_api.dart';
import 'package:yomi/core/spotify/missing_songs.dart';
import 'package:yomi/core/subsonic_client.dart';
import 'package:yomi/state/reports_controller.dart';

const _song = Song(
  id: 's1',
  title: 'Blue Hour',
  artist: 'Mira',
  album: 'Night Drive',
  durationSeconds: 200,
);

Map<String, dynamic> _reportJson({
  String id = 'r1',
  String kind = 'missing_song',
  String status = 'open',
  int count = 1,
}) => {
  'id': id,
  'kind': kind,
  'artist': 'Mira',
  'title': 'Blue Hour',
  'status': status,
  'count': count,
  'createdMs': 1,
  'updatedMs': 2,
};

class _Server {
  final requests = <http.Request>[];
  bool isAdmin = false;
  List<Map<String, dynamic>> reports = [];

  http.Client get client => MockClient((request) async {
    requests.add(request);
    if (request.method == 'GET') {
      return http.Response(
        jsonEncode({'reports': reports, 'isAdmin': isAdmin}),
        200,
      );
    }
    return http.Response(jsonEncode(_reportJson()), 201);
  });

  ReportsApi api() => ReportsApi(
    serverUrl: 'http://server',
    auth: SubsonicClient(
      baseUrl: 'http://server',
      username: 'u',
      password: 'p',
    ),
    port: 8443,
    httpClient: client,
  );
}

void main() {
  group('ReportsApi', () {
    test('sends a song problem with what identifies the song', () async {
      // Arrange
      final server = _Server();

      // Act
      await server.api().add(
        ReportInput.forSong(
          _song,
          ReportKind.explicitWanted,
          note: 'radio edit',
        ),
      );

      // Assert
      final sent = jsonDecode(server.requests.single.body) as Map;
      expect(server.requests.single.url.path, '/v1/reports');
      expect(server.requests.single.url.port, 8443);
      expect(sent['kind'], 'explicit_wanted');
      expect(sent['songId'], 's1');
      expect(sent['note'], 'radio edit');
    });

    test('reads reports and whether this account is the admin', () async {
      // Arrange
      final server = _Server()
        ..isAdmin = true
        ..reports = [_reportJson(count: 3)];

      // Act
      final page = await server.api().list();

      // Assert
      expect(page.isAdmin, isTrue);
      expect(page.reports.single.kind, ReportKind.missingSong);
      expect(page.reports.single.count, 3);
      expect(page.reports.single.isOpen, isTrue);
    });

    test('ignores reports of a kind this app does not know', () async {
      // Arrange
      final server = _Server()..reports = [_reportJson(kind: 'future_kind')];

      // Act
      final page = await server.api().list();

      // Assert
      expect(page.reports, isEmpty);
    });
  });

  group('ReportsController', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    Future<(ReportsController, _Server)> attached() async {
      final server = _Server();
      final controller = ReportsController(
        await SharedPreferences.getInstance(),
      );
      controller.attach(server.api());
      return (controller, server);
    }

    test('reporting refreshes the list', () async {
      // Arrange
      final (controller, server) = await attached();
      server.reports = [_reportJson()];

      // Act
      final isSent = await controller.report(
        ReportInput.forSong(_song, ReportKind.coverWrong),
      );

      // Assert
      expect(isSent, isTrue);
      expect(controller.reports, hasLength(1));
    });

    test(
      'songs missing from imports are requested once, not every launch',
      () async {
        // Arrange
        final (controller, server) = await attached();
        const missing = [
          MissingSong(artist: 'Mira', title: 'Blue Hour', playlists: ['Mix']),
        ];

        // Act
        await controller.requestMissing(missing);
        await controller.requestMissing(missing);

        // Assert
        final posts = server.requests.where((r) => r.method == 'POST').toList();
        expect(posts, hasLength(1));
        expect((jsonDecode(posts.single.body) as Map)['kind'], 'missing_song');
      },
    );

    test('a failed report says so instead of pretending', () async {
      // Arrange
      final controller = ReportsController(
        await SharedPreferences.getInstance(),
      );
      controller.attach(
        ReportsApi(
          serverUrl: 'http://server',
          auth: SubsonicClient(
            baseUrl: 'http://server',
            username: 'u',
            password: 'p',
          ),
          port: 8443,
          httpClient: MockClient((_) async => http.Response('{}', 500)),
        ),
      );

      // Act
      final isSent = await controller.report(
        ReportInput.forSong(_song, ReportKind.other),
      );

      // Assert
      expect(isSent, isFalse);
      expect(controller.error, isNotNull);
    });

    test('saving a requested song closes its request', () async {
      // Arrange
      final (controller, server) = await attached();
      server.reports = [_reportJson(id: 'want')];
      await controller.refresh();

      // Act
      await controller.markAddedMatching('mira', '  Blue  Hour ');

      // Assert
      final post = server.requests.lastWhere((r) => r.method == 'POST');
      expect(post.url.path, '/v1/reports/want/added');
    });

    test('open reports come first', () async {
      // Arrange
      final (controller, server) = await attached();
      server.reports = [
        _reportJson(id: 'done', status: 'resolved'),
        _reportJson(id: 'open'),
      ];

      // Act
      await controller.refresh();

      // Assert
      expect(controller.reports.first.id, 'open');
    });
  });
}
