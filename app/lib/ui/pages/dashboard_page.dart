import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/server_status.dart';
import '../../state/dashboard_controller.dart';
import '../../state/reports_controller.dart';
import '../../state/session.dart';
import '../theme.dart';
import '../widgets/reports_section.dart';
import '../widgets/yomi_refresh.dart';

void openDashboard(BuildContext context) {
  final session = context.read<SessionController>();
  Navigator.of(context, rootNavigator: true).push(
    yomiRoute<void>(
      builder: (_) => ChangeNotifierProvider<DashboardController>(
        create: (_) {
          final statusClient = ServerStatusClient(
            serverUrl: session.serverUrl,
            auth: session.client,
            port: session.uploadServicePort,
          );
          return DashboardController(
            fetchStatus: statusClient.fetch,
            ping: session.client.ping,
          )..start();
        },
        child: DashboardPage(routeLabel: session.routeLabel),
      ),
    ),
  );
}

String formatBytes(int bytes) {
  const gb = 1024 * 1024 * 1024;
  const mb = 1024 * 1024;
  if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(1)} GB';
  return '${(bytes / mb).round()} MB';
}

String formatUptime(Duration uptime) {
  if (uptime.inDays >= 1) {
    return '${uptime.inDays} d ${uptime.inHours % 24} h';
  }
  if (uptime.inHours >= 1) {
    return '${uptime.inHours} h ${uptime.inMinutes % 60} min';
  }
  return '${uptime.inMinutes} min';
}

String _describeBattery(BatteryStatus battery) => [
  '${battery.level}%',
  if (battery.isCharging == true) 'charging',
  if (battery.isCharging == false) 'not charging',
  if (battery.temperatureC != null)
    '${battery.temperatureC!.toStringAsFixed(1)} °C',
  if (battery.health != null && battery.health != 'unknown')
    '${battery.health} health',
  if (battery.isStale) 'last report is old',
].join(' · ');

/// Server health at a glance. Details are for admins; others just see if it's online.
class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key, required this.routeLabel});

  final String routeLabel;

  @override
  Widget build(BuildContext context) {
    final dashboard = context.watch<DashboardController>();
    final status = dashboard.status;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Server status',
          style: yomiText(20, weight: FontWeight.w800),
        ),
      ),
      body: YomiRefresh(
        onRefresh: dashboard.refresh,
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            kPagePadding,
            YomiSpace.s,
            kPagePadding,
            MediaQuery.paddingOf(context).bottom + YomiSpace.xxl,
          ),
          children: [
            _Headline(dashboard: dashboard),
            const SizedBox(height: YomiSpace.xl),
            // Absent in builds and tests without a server connection.
            if (Provider.of<ReportsController?>(context, listen: false) !=
                null) ...[
              const ReportsSection(),
              const SizedBox(height: YomiSpace.xl),
            ],
            _Group(
              title: 'This device',
              rows: [
                _Row('Connection', routeLabel),
                _Row(
                  'Response time',
                  dashboard.deviceLatency == null
                      ? 'Unknown'
                      : '${dashboard.deviceLatency!.inMilliseconds} ms',
                ),
              ],
            ),
            if (status != null && status.isDetailed)
              ..._details(status)
            else if (dashboard.reachability == ServerReachability.online)
              Padding(
                padding: const EdgeInsets.only(top: YomiSpace.l),
                child: Text(
                  'Only the server admin sees more detail here.',
                  style: yomiText(
                    13,
                    weight: FontWeight.w500,
                    color: YomiColors.textSecondary,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _details(ServerStatus status) => [
    const SizedBox(height: YomiSpace.xl),
    _Group(
      title: 'Music server',
      rows: [
        _Row('Navidrome', switch (status.isNavidromeHealthy) {
          true =>
            status.navidromeLatency == null
                ? 'Responding'
                : 'Responding in ${status.navidromeLatency!.inMilliseconds} ms',
          false => 'Not responding',
          null => 'Unknown',
        }),
        _Row('Library scan', status.isScanning ? 'Scanning now' : 'Idle'),
        _Row('Songs', status.songCount?.toString() ?? 'Unknown'),
        if (status.indexedSongs != null)
          _Row(
            'Duplicate index',
            status.isIndexing
                ? '${status.indexedSongs} songs, still indexing'
                : '${status.indexedSongs} songs',
          ),
        _Row('Tailscale', status.tailscale ?? 'Unknown'),
      ],
    ),
    const SizedBox(height: YomiSpace.xl),
    _Group(
      title: 'Phone',
      rows: [
        _Row(
          'Battery',
          status.battery == null
              ? 'Unknown'
              : _describeBattery(status.battery!),
        ),
        _Row(
          'Uptime',
          status.uptime == null ? 'Unknown' : formatUptime(status.uptime!),
        ),
        _Row('Load', status.load?.toStringAsFixed(2) ?? 'Unknown'),
      ],
    ),
    const SizedBox(height: YomiSpace.xl),
    _SpaceMeter(label: 'Memory', usage: status.memory),
    _SpaceMeter(label: 'Music storage', usage: status.card),
    _SpaceMeter(label: 'Internal storage', usage: status.internal),
  ];
}

class _Headline extends StatelessWidget {
  const _Headline({required this.dashboard});

  final DashboardController dashboard;

  @override
  Widget build(BuildContext context) {
    final isMusicDown = dashboard.status?.isNavidromeHealthy == false;
    final (icon, color, title, detail) = switch (dashboard.reachability) {
      ServerReachability.checking => (
        Icons.sync_rounded,
        YomiColors.textSecondary,
        'Checking',
        'Asking the server how it is.',
      ),
      ServerReachability.offline => (
        Icons.cloud_off_rounded,
        YomiColors.danger,
        'Offline',
        "Can't reach the server from this device.",
      ),
      ServerReachability.needsUpdate => (
        Icons.system_update_alt_rounded,
        YomiColors.textSecondary,
        'Online',
        'The server needs updating to report its health.',
      ),
      ServerReachability.online when isMusicDown => (
        Icons.error_rounded,
        YomiColors.danger,
        'Music server not responding',
        'The server is on, but Navidrome is not answering.',
      ),
      ServerReachability.online => (
        Icons.check_circle_rounded,
        YomiColors.success,
        'Online',
        'Everything is responding.',
      ),
    };
    return Row(
      children: [
        Icon(icon, color: color, size: 32),
        const SizedBox(width: YomiSpace.m),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: yomiText(22, weight: FontWeight.w800)),
              Text(
                detail,
                style: yomiText(
                  13.5,
                  weight: FontWeight.w500,
                  color: YomiColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Row {
  const _Row(this.label, this.value);

  final String label;
  final String value;
}

class _Group extends StatelessWidget {
  const _Group({required this.title, required this.rows});

  final String title;
  final List<_Row> rows;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: yomiText(16, weight: FontWeight.w800)),
        const SizedBox(height: YomiSpace.s),
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: YomiSpace.xs),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    row.label,
                    style: yomiText(
                      14,
                      weight: FontWeight.w500,
                      color: YomiColors.textSecondary,
                    ),
                  ),
                ),
                const SizedBox(width: YomiSpace.l),
                Expanded(
                  flex: 2,
                  child: Text(
                    row.value,
                    textAlign: TextAlign.end,
                    style: yomiText(14, weight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _SpaceMeter extends StatelessWidget {
  const _SpaceMeter({required this.label, required this.usage});

  final String label;
  final SpaceUsage? usage;

  @override
  Widget build(BuildContext context) {
    final space = usage;
    return Padding(
      padding: const EdgeInsets.only(bottom: YomiSpace.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: yomiText(
                    14,
                    weight: FontWeight.w500,
                    color: YomiColors.textSecondary,
                  ),
                ),
              ),
              Text(
                space == null
                    ? 'Unknown'
                    : '${formatBytes(space.free)} free of ${formatBytes(space.total)}',
                style: yomiText(14, weight: FontWeight.w600),
              ),
            ],
          ),
          if (space != null) ...[
            const SizedBox(height: YomiSpace.xs),
            ClipRRect(
              borderRadius: BorderRadius.circular(YomiRadius.pill),
              child: LinearProgressIndicator(
                value: space.usedShare,
                minHeight: 4,
                color: YomiColors.textPrimary,
                backgroundColor: YomiColors.surfaceHigh,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
