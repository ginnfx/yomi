import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/connection_probe.dart';
import '../core/lan_discovery.dart';
import '../core/subsonic_client.dart';
import '../core/upload_client.dart';
import 'connectivity_controller.dart';

const int _defaultNavidromePort = 4533;
const Duration _homeProbeTimeout = Duration(milliseconds: 1500);
const Duration _routeDebounce = Duration(milliseconds: 700);
const Duration _reachTimeout = Duration(seconds: 4);
const Duration _reachRetryEvery = Duration(seconds: 15);
const String _awayKey = 'server_url';
const String _homeKey = 'home_url';
const String _extraKey = 'extra_urls';
const Duration _scanEvery = Duration(seconds: 30);
const String _modeKey = 'route_mode';
const String _userKey = 'username';
const String _passwordKey = 'password';

/// Turns "100.88.180.104" or "http://host" into "http://host:4533".
String normalizeServerUrl(String input) {
  var text = input.trim();
  if (text.isEmpty) return text;
  if (!text.contains('://')) text = 'http://$text';
  final uri = Uri.parse(text);
  final needsPort = !uri.hasPort && uri.scheme == 'http';
  return uri
      .replace(port: needsPort ? _defaultNavidromePort : null, path: '')
      .toString()
      .replaceAll(RegExp(r'/+$'), '');
}

/// How Yomi picks which address to use.
enum RouteMode { auto, home, away }

enum ActiveRoute { home, away }

typedef HomeProbe = Future<bool> Function(
  String url,
  String user,
  String password,
);

Future<bool> _pingProbe(String url, String user, String password) async {
  try {
    await SubsonicClient(
      baseUrl: url,
      username: user,
      password: password,
    ).ping(timeout: _homeProbeTimeout);
    return true;
  } on Exception {
    return false;
  }
}

/// Holds the signed-in account and the clients built from it. With a home and an away
/// address saved, it checks which one works and switches by itself when the network changes.
class SessionController extends ChangeNotifier {
  SessionController({
    FlutterSecureStorage? storage,
    ConnectivityController? connectivity,
    HomeProbe? probe,
    UrlProbe? urlProbe,
    LanFinder? lanFinder,
  }) : _storage =
           storage ??
           const FlutterSecureStorage(
             // The login Keychain works for locally built Mac apps without a
             // provisioning profile; credentials still stay in Apple's Keychain.
             mOptions: MacOsOptions(usesDataProtectionKeychain: false),
           ),
       _connectivity = connectivity,
       _probe = probe ?? _pingProbe,
       _urlProbe = urlProbe ?? probeUrl,
       _lanFinder = lanFinder ?? findServerOnLan {
    _connectivity?.addListener(_onNetworkChanged);
  }

  final FlutterSecureStorage _storage;
  final ConnectivityController? _connectivity;
  final HomeProbe _probe;
  final UrlProbe _urlProbe;
  final LanFinder _lanFinder;
  bool _isScanning = false;
  DateTime? _lastScan;
  List<String> _extraUrls = const [];
  bool _isOnBackup = false;

  SubsonicClient? _client;
  UploadClient? _uploader;
  String? _awayUrl;
  String? _homeUrl;
  String _user = '';
  String _password = '';
  RouteMode _mode = RouteMode.auto;
  ActiveRoute _route = ActiveRoute.away;
  bool _isRestoring = true;
  bool _isResolving = false;
  Timer? _debounce;
  Timer? _reachRetry;
  bool _isServerReachable = true;
  bool _isChecking = false;

  /// False once a quick check fails; the app then shows the offline screen and keeps retrying.
  bool get isServerReachable => _isServerReachable;
  bool get isChecking => _isChecking;

  /// Extra addresses tried, in order, when the main ones don't answer.
  List<String> get extraUrls => List.unmodifiable(_extraUrls);
  bool get isOnBackup => _isOnBackup;

  /// Every address Yomi knows, best first, without repeats.
  List<String> get candidateUrls => {
    if (_homeUrl != null) _homeUrl!,
    if (_awayUrl != null) _awayUrl!,
    ..._extraUrls,
  }.toList();

  bool get isRestoring => _isRestoring;
  bool get isSignedIn => _client != null;
  SubsonicClient get client => _client!;
  UploadClient get uploader => _uploader!;
  String get username => _user;
  String get serverUrl => _client?.baseUrl ?? '';
  String get awayUrl => _awayUrl ?? '';
  String get homeUrl => _homeUrl ?? '';
  RouteMode get mode => _mode;
  ActiveRoute get route => _route;
  bool get isResolving => _isResolving;
  bool get hasHomeAddress => (_homeUrl ?? '').isNotEmpty;

  String get routeLabel => _isOnBackup
      ? 'Backup address'
      : switch (_route) {
          ActiveRoute.home => 'Home network',
          ActiveRoute.away => hasHomeAddress ? 'Away from home' : 'Connected',
        };

  Future<void> restore() async {
    try {
      final away = await _storage.read(key: _awayKey);
      final user = await _storage.read(key: _userKey);
      final password = await _storage.read(key: _passwordKey);
      if (away != null && user != null && password != null) {
        _awayUrl = away;
        _homeUrl = await _storage.read(key: _homeKey);
        _extraUrls = _decodeUrls(await _storage.read(key: _extraKey));
        final savedMode = await _storage.read(key: _modeKey);
        _mode = RouteMode.values.firstWhere(
          (m) => m.name == savedMode,
          orElse: () => RouteMode.auto,
        );
        _user = user;
        _password = password;
        _route = ActiveRoute.away;
        _build(away);
        await refreshRoute();
      }
    } on Exception catch (error) {
      debugPrint('Could not restore session: $error');
    } finally {
      _isRestoring = false;
      notifyListeners();
    }
    if (_client != null) unawaited(checkServer());
  }

  /// Verifies the credentials with the server before saving them. [homeInput] is the optional
  /// address to use on your home Wi-Fi; [serverInput] is used everywhere else.
  Future<void> signIn(
    String serverInput,
    String user,
    String password, {
    String homeInput = '',
  }) async {
    final away = normalizeServerUrl(serverInput);
    final home = normalizeServerUrl(homeInput);
    if (away.isEmpty || user.trim().isEmpty || password.isEmpty) {
      throw const SubsonicException(
        'Enter the server address, username and password.',
      );
    }
    // The account works on home Wi-Fi even when Tailscale is disconnected.
    final homeWorks =
        home.isNotEmpty &&
        (_connectivity == null || _connectivity.isOnWifi) &&
        await _probe(home, user.trim(), password);
    if (!homeWorks) {
      await SubsonicClient(
        baseUrl: away,
        username: user.trim(),
        password: password,
      ).ping();
    }
    _awayUrl = away;
    _homeUrl = home.isEmpty ? null : home;
    _mode = RouteMode.auto;
    _user = user.trim();
    _password = password;
    await _remember();
    _route = homeWorks ? ActiveRoute.home : ActiveRoute.away;
    _build(homeWorks ? home : away);
    notifyListeners();
    await refreshRoute();
  }

  /// Saves new addresses and/or mode from Settings, then re-checks which one to use.
  Future<void> updateConnection({
    String? home,
    String? away,
    RouteMode? mode,
  }) async {
    if (home != null)
      _homeUrl = normalizeServerUrl(home).isEmpty
          ? null
          : normalizeServerUrl(home);
    if (away != null && normalizeServerUrl(away).isNotEmpty)
      _awayUrl = normalizeServerUrl(away);
    if (mode != null) _mode = mode;
    await _remember();
    await refreshRoute();
  }

  /// Decides between home and away: on home Wi-Fi it probes the home address quickly,
  /// anywhere else it uses the away address. Safe to call often.
  Future<void> refreshRoute() async {
    if (_client == null || _isResolving) return;
    _isResolving = true;
    notifyListeners();
    try {
      final chosen = await _chooseRoute();
      final url = chosen == ActiveRoute.home
          ? _homeUrl!
          : (_awayUrl ?? _homeUrl!);
      if (chosen != _route || url != _client!.baseUrl) {
        _route = chosen;
        _isOnBackup = false;
        _build(url);
      }
    } finally {
      _isResolving = false;
      notifyListeners();
    }
  }

  /// Quick reachability check for the current address. Flips to offline mode on failure and
  /// retries on its own until the server answers again.
  Future<void> checkServer() async {
    final client = _client;
    if (client == null || _isChecking) return;
    _isChecking = true;
    notifyListeners();
    var reachable = false;
    try {
      await client.ping(timeout: _reachTimeout);
      reachable = true;
    } on Exception {
      reachable = await _failOver(client.baseUrl);
    }
    _isChecking = false;
    _reachRetry?.cancel();
    if (!reachable) {
      _reachRetry = Timer(_reachRetryEvery, checkServer);
      unawaited(_healHome());
    }
    _isServerReachable = reachable;
    notifyListeners();
  }

  /// The current address is dead: try every other known address at once and switch to the
  /// first one (in priority order) that answers.
  Future<bool> _failOver(String deadUrl) async {
    final others = candidateUrls.where((u) => u != deadUrl).toList();
    if (others.isEmpty) return false;
    final results = await Future.wait(
      others.map((u) => _urlProbe(u, _user, _password)),
    );
    final working = results.where((r) => r.isOk).toList();
    if (working.isEmpty) return false;
    _isOnBackup = true;
    _build(working.first.url);
    return true;
  }

  /// Tries every known address and reports how each one did. Used by the Connection doctor.
  Future<List<ProbeResult>> diagnose() =>
      Future.wait(candidateUrls.map((u) => _urlProbe(u, _user, _password)));

  /// Switches to [url] by hand, e.g. from the doctor, after it answered.
  void useUrl(String url) {
    if (_client == null) return;
    _isOnBackup = url != _awayUrl && url != _homeUrl;
    _route = url == _homeUrl ? ActiveRoute.home : ActiveRoute.away;
    _build(url);
    _isServerReachable = true;
    _reachRetry?.cancel();
    notifyListeners();
  }

  Future<void> addExtraUrl(String input) async {
    final url = normalizeServerUrl(input);
    if (url.isEmpty || candidateUrls.contains(url)) return;
    _extraUrls = [..._extraUrls, url];
    await _remember();
    notifyListeners();
  }

  Future<void> removeExtraUrl(String url) async {
    _extraUrls = _extraUrls.where((u) => u != url).toList();
    await _remember();
    notifyListeners();
  }

  static List<String> _decodeUrls(String? raw) {
    if (raw == null) return const [];
    try {
      final decoded = jsonDecode(raw);
      return decoded is List ? decoded.whereType<String>().toList() : const [];
    } on FormatException {
      return const [];
    }
  }

  Future<ActiveRoute> _chooseRoute() async {
    if (!hasHomeAddress) return ActiveRoute.away;
    return switch (_mode) {
      RouteMode.home => ActiveRoute.home,
      RouteMode.away => ActiveRoute.away,
      RouteMode.auto => await _autoRoute(),
    };
  }

  Future<ActiveRoute> _autoRoute() async {
    // Off Wi-Fi there is no way to be on the home network, so skip the probe.
    if (_connectivity != null && !_connectivity.isOnWifi)
      return ActiveRoute.away;
    if (await _probe(_homeUrl!, _user, _password)) return ActiveRoute.home;
    unawaited(_healHome());
    return ActiveRoute.away;
  }

  /// The saved home address stopped answering, usually because the router handed the server
  /// a new IP. Looks for it on this Wi-Fi and, if found, saves it as the new home address.
  Future<void> _healHome() async {
    final last = _lastScan;
    final isRecent =
        last != null && DateTime.now().difference(last) < _scanEvery;
    final isOnOtherNetwork = _connectivity != null && !_connectivity.isOnWifi;
    if (_isScanning || isRecent || isOnOtherNetwork || _client == null) return;
    _isScanning = true;
    _lastScan = DateTime.now();
    try {
      final found = await _lanFinder(_user, _password);
      if (found == null || _client == null) return;
      final isNew = found != _homeUrl;
      _homeUrl = found;
      if (isNew) await _remember();
      if (_mode != RouteMode.away || !_isServerReachable) {
        _reachRetry?.cancel();
        useUrl(found);
      } else {
        notifyListeners();
      }
    } on Exception catch (error) {
      debugPrint('Home address search failed: $error');
    } finally {
      _isScanning = false;
    }
  }

  void _onNetworkChanged() {
    _debounce?.cancel();
    _debounce = Timer(_routeDebounce, () async {
      await refreshRoute();
      await checkServer();
    });
  }

  Future<void> signOut() async {
    try {
      await _storage.deleteAll();
    } on Exception catch (error) {
      debugPrint('Could not clear saved sign-in: $error');
    }
    _reachRetry?.cancel();
    _isServerReachable = true;
    _client = null;
    _uploader = null;
    _awayUrl = null;
    _homeUrl = null;
    _extraUrls = const [];
    _isOnBackup = false;
    _user = '';
    _password = '';
    notifyListeners();
  }

  /// Saving is best effort: if the keychain is unavailable the user can still listen,
  /// they just have to sign in again next launch.
  Future<void> _remember() async {
    try {
      await _storage.write(key: _awayKey, value: _awayUrl);
      await _storage.write(key: _homeKey, value: _homeUrl);
      await _storage.write(key: _modeKey, value: _mode.name);
      await _storage.write(key: _extraKey, value: jsonEncode(_extraUrls));
      await _storage.write(key: _userKey, value: _user);
      await _storage.write(key: _passwordKey, value: _password);
    } on Exception catch (error) {
      debugPrint('Could not save sign-in: $error');
    }
  }

  void _build(String url) {
    _client = SubsonicClient(
      baseUrl: url,
      username: _user,
      password: _password,
    );
    _uploader = UploadClient(serverUrl: url, auth: _client!);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _reachRetry?.cancel();
    _connectivity?.removeListener(_onNetworkChanged);
    super.dispose();
  }
}
