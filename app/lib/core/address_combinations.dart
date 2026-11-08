/// Every address that can be made by mixing the schemes, hosts and ports of the addresses
/// Yomi already knows, so the Connection doctor can find a working one that was never typed
/// in (a phone's Tailscale IP with the Mac's port, a backup host over another scheme...).
library;

const int kDefaultNavidromePort = 4533;
const int kMaxCombinations = 24;

typedef _Parts = ({String scheme, String host, int? port});

/// Combinations of [known] addresses' schemes, hosts and ports, plus [extraHosts] (bare
/// hosts such as `100.64.0.2` or `my-mac`). Addresses already in [known] are left out.
/// Order is stable: hosts in the order met, then ports, then schemes; capped at [max].
List<String> addressCombinations(
  Iterable<String> known, {
  Iterable<String> extraHosts = const [],
  int max = kMaxCombinations,
}) {
  final parsed = [for (final url in known) ?_parts(url)];
  final schemes = {for (final p in parsed) p.scheme};
  final ports = {for (final p in parsed) p.port};
  final hosts = {
    for (final p in parsed) p.host,
    for (final h in extraHosts)
      if (h.trim().isNotEmpty) h.trim(),
  };
  if (schemes.isEmpty) schemes.add('http');
  if (ports.isEmpty) ports.add(kDefaultNavidromePort);
  final existing = {for (final p in parsed) _format(p)};
  final result = <String>[];
  for (final host in hosts) {
    for (final port in ports) {
      for (final scheme in schemes) {
        final url = _format((scheme: scheme, host: host, port: port));
        if (existing.contains(url) || result.contains(url)) continue;
        result.add(url);
        if (result.length >= max) return List.unmodifiable(result);
      }
    }
  }
  return List.unmodifiable(result);
}

_Parts? _parts(String url) {
  final text = url.contains('://') ? url : 'http://$url';
  final uri = Uri.tryParse(text);
  if (uri == null || uri.host.isEmpty) return null;
  final isHttp = uri.scheme == 'http';
  return (
    scheme: uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : (isHttp ? kDefaultNavidromePort : null),
  );
}

String _format(_Parts p) =>
    '${p.scheme}://${p.host}${p.port == null ? '' : ':${p.port}'}';
