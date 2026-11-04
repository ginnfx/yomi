import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'subsonic_client.dart';
import 'upload/bulk_upload_api.dart';

const Duration _statusTimeout = Duration(seconds: 10);

@immutable
class SpaceUsage {
  const SpaceUsage(this.total, this.free);

  static SpaceUsage? tryParse(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final total = (json['total'] as num?)?.toInt();
    final free = (json['free'] as num?)?.toInt();
    if (total == null || free == null || total <= 0) return null;
    return SpaceUsage(total, free);
  }

  final int total;
  final int free;

  int get used => total - free;
  double get usedShare => (used / total).clamp(0.0, 1.0);
}

@immutable
class BatteryStatus {
  const BatteryStatus({
    required this.level,
    this.isCharging,
    this.health,
    this.temperatureC,
    this.isStale = false,
  });

  static BatteryStatus? tryParse(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final level = (json['level'] as num?)?.toInt();
    if (level == null) return null;
    return BatteryStatus(
      level: level,
      isCharging: json['charging'] as bool?,
      health: json['health'] as String?,
      temperatureC: (json['temperatureC'] as num?)?.toDouble(),
      isStale: json['stale'] == true,
    );
  }

  final int level;
  final bool? isCharging;
  final String? health;
  final double? temperatureC;
  final bool isStale;
}

@immutable
class ServerStatus {
  const ServerStatus({
    this.isDetailed = false,
    this.uptime,
    this.load,
    this.memory,
    this.card,
    this.internal,
    this.battery,
    this.isNavidromeHealthy,
    this.navidromeLatency,
    this.isScanning = false,
    this.songCount,
    this.tailscale,
    this.indexedSongs,
    this.isIndexing = false,
  });

  /// Unknown or unexpected values come through as null, shown as "Unknown".
  factory ServerStatus.fromJson(Map<String, dynamic> json) {
    final navidrome = json['navidrome'];
    final nd = navidrome is Map<String, dynamic> ? navidrome : null;
    final uptime = (json['uptimeSeconds'] as num?)?.toInt();
    final latency = (nd?['latencyMs'] as num?)?.toInt();
    return ServerStatus(
      isDetailed: json['detailed'] == true,
      uptime: uptime == null ? null : Duration(seconds: uptime),
      load: (json['load1'] as num?)?.toDouble(),
      memory: SpaceUsage.tryParse(json['memory']),
      card: SpaceUsage.tryParse(json['card']),
      internal: SpaceUsage.tryParse(json['internal']),
      battery: BatteryStatus.tryParse(json['battery']),
      isNavidromeHealthy: nd?['healthy'] as bool?,
      navidromeLatency: latency == null
          ? null
          : Duration(milliseconds: latency),
      isScanning: nd?['scanning'] == true,
      songCount: (nd?['songCount'] as num?)?.toInt(),
      tailscale: json['tailscale'] as String?,
      indexedSongs: (json['indexedSongs'] as num?)?.toInt(),
      isIndexing: json['indexing'] == true,
    );
  }

  final bool isDetailed;
  final Duration? uptime;
  final double? load;
  final SpaceUsage? memory;
  final SpaceUsage? card;
  final SpaceUsage? internal;
  final BatteryStatus? battery;
  final bool? isNavidromeHealthy;
  final Duration? navidromeLatency;
  final bool isScanning;
  final int? songCount;
  final String? tailscale;
  final int? indexedSongs;
  final bool isIndexing;
}

/// The server is running a version without the status route.
class StatusRouteMissing implements Exception {
  const StatusRouteMissing();
}

/// Fetches server health from the upload service.
class ServerStatusClient {
  ServerStatusClient({
    required this.serverUrl,
    required this.auth,
    this.port = uploadPort,
  });

  final String serverUrl;
  final SubsonicClient auth;
  final int port;

  Future<ServerStatus> fetch() async {
    final client = HttpClient()..connectionTimeout = _statusTimeout;
    try {
      final uri = Uri.parse(serverUrl.replaceAll(RegExp(r'/+$'), '')).replace(
        port: port,
        path: '/v1/status',
        queryParameters: auth.authParams(),
      );
      final request = await client.getUrl(uri).timeout(_statusTimeout);
      final response = await request.close().timeout(_statusTimeout);
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(_statusTimeout);
      if (response.statusCode == HttpStatus.notFound) {
        throw const StatusRouteMissing();
      }
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('Status answered ${response.statusCode}');
      }
      return ServerStatus.fromJson(jsonDecode(body) as Map<String, dynamic>);
    } finally {
      client.close(force: true);
    }
  }
}
