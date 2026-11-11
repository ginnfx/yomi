/// The same personal server is used by all Yomi clients. No credentials are built in.
const defaultServerUrl = String.fromEnvironment(
  'YOMI_SERVER',
  defaultValue: 'http://100.82.99.19:4533',
);
const defaultHomeServerUrl = String.fromEnvironment(
  'YOMI_HOME_SERVER',
  defaultValue: '',
);

/// Standby addresses for the same library. Tailscale addresses keep working when
/// the Mac changes Wi-Fi. The Connection doctor tries each with every known port and
/// scheme. Comma separated; override at build time with YOMI_HOSTS.
const _extraHostsText = String.fromEnvironment(
  'YOMI_HOSTS',
  defaultValue: '100.105.93.93,brajans-macbook-air',
);
final List<String> defaultExtraHosts = List.unmodifiable(
  _extraHostsText.split(',').map((h) => h.trim()).where((h) => h.isNotEmpty),
);
