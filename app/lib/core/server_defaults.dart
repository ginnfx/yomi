/// The same personal server is used by all Yomi clients. No credentials are built in.
const defaultServerUrl = String.fromEnvironment(
  'YOMI_SERVER',
  defaultValue: 'http://100.88.180.104:4533',
);
const defaultHomeServerUrl = String.fromEnvironment(
  'YOMI_HOME_SERVER',
  defaultValue: 'http://192.168.1.18:4533',
);

/// Other machines that can serve the same library (the Mac and the always-on VM, by LAN IP,
/// Tailscale IP and name). The Connection doctor tries each with every known port and
/// scheme. Comma separated; override at build time with YOMI_HOSTS.
const _extraHostsText = String.fromEnvironment(
  'YOMI_HOSTS',
  defaultValue: '192.168.1.76,100.105.93.93,brajans-macbook-air,100.82.99.19',
);
final List<String> defaultExtraHosts = List.unmodifiable(
  _extraHostsText.split(',').map((h) => h.trim()).where((h) => h.isNotEmpty),
);
