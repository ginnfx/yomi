const cloudMusicUrl = 'http://100.82.99.19:4533';
const macMusicUrl = 'http://100.105.93.93:4533';
const cloudTopologyVersion = 'cloud-primary-v1';

const _managedMainUrls = {
  cloudMusicUrl,
  macMusicUrl,
  'http://100.88.180.104:4533',
  'http://brajans-macbook-air:4533',
};
const _oldHomeUrls = {
  'http://192.168.1.18:4533',
  'http://192.168.1.23:4533',
  'http://192.168.1.76:4533',
  'http://192.168.1.10:4533',
};

/// One-time upgrade for this personal deployment, preserving custom deployments.
/// No credentials or account identity are changed.
({String away, String? home, List<String> extras})? migrateCloudTopology({
  required String away,
  required String? home,
  required List<String> extras,
}) {
  if (!_managedMainUrls.contains(away) && !_oldHomeUrls.contains(away)) {
    return null;
  }
  return (
    away: cloudMusicUrl,
    home: _oldHomeUrls.contains(home) || _managedMainUrls.contains(home)
        ? null
        : home,
    extras: {
      macMusicUrl,
      for (final url in extras)
        if (!_oldHomeUrls.contains(url) && !_managedMainUrls.contains(url)) url,
    }.toList(),
  );
}

/// Adds the standby server for accounts on the built-in cloud server, so there is
/// somewhere to fail over to without setting anything up. Any other main address is
/// someone's own deployment and is returned untouched.
List<String> withDefaultBackup({
  required String away,
  required String? home,
  required List<String> extras,
}) {
  final isKnown = home == macMusicUrl || extras.contains(macMusicUrl);
  if (away != cloudMusicUrl || isKnown) return extras;
  return [...extras, macMusicUrl];
}
