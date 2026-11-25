import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/widgets.dart';

import 'cover_crop.dart';

/// Login parameters that change between sessions or addresses without changing the
/// picture. `v` is kept: some services use it for the picture's version.
const Set<String> _authParams = {'u', 't', 's', 'c', 'f'};

/// A key for [url] that stays the same across logins and server addresses, so a saved
/// picture is found again instead of fetched again.
String savedImageKey(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return 'img-$url';
  final query = {
    for (final entry in uri.queryParameters.entries)
      if (!_authParams.contains(entry.key)) entry.key: entry.value,
  };
  final sorted = (query.keys.toList()..sort())
      .map((key) => '$key=${query[key]}')
      .join('&');
  // Pictures from the user's own server are the same at home and away.
  final isOutside =
      uri.scheme == 'https' &&
      !_authParams.any(uri.queryParameters.containsKey);
  final origin = isOutside ? uri.host : '';
  return 'img-$origin${uri.path}${sorted.isEmpty ? '' : '?$sorted'}';
}

/// A picture kept on this device, so it shows straight away and offline, such as
/// playlist covers, profile pictures and banners.
ImageProvider savedImage(String url) => CachedNetworkImageProvider(
  url,
  cacheKey: savedImageKey(url),
  cacheManager: coverCacheManager,
);
