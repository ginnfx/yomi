import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/vault_storage.dart';

import 'package:http/http.dart' as http;

import '../core/address_combinations.dart';
import '../core/connection_probe.dart';
import '../core/server_defaults.dart';
import '../core/server_topology.dart';
import '../core/server_pool.dart';
import '../core/lan_discovery.dart';
import '../core/subsonic_client.dart';
import '../core/catalog_cache.dart';
import '../core/messaging/messaging_api.dart';
import '../core/offline/outbox.dart';
import '../core/server_role.dart';
import '../core/upload/bulk_upload_api.dart';
import 'connectivity_controller.dart';

const int _defaultNavidromePort = 4533;
const Duration _homeProbeTimeout = Duration(milliseconds: 1500);
const Duration _routeDebounce = Duration(milliseconds: 700);
const Duration _reachTimeout = Duration(seconds: 4);

/// Networks take a moment to wake up, so routine checks wait longer and try twice before
/// anything on screen changes.
const Duration _wakeTimeout = Duration(seconds: 8);
const int _routineAttempts = 2;
const Duration _reachRetryEvery = Duration(seconds: 15);

/// How long a better address may still answer after a lower-priority one already has.
const Duration _failoverGrace = Duration(milliseconds: 1500);
const Duration _primaryRetryEvery = Duration(seconds: 60);
const Duration _roleRetryAfter = Duration(seconds: 15);
const List<String> _secureKeys = [
  _accountKey,
  _lastUrlKey,
  _awayKey,
  _homeKey,
  _extraKey,
  _modeKey,
  _userKey,
  _passwordKey,
  _topologyKey,
];
const String _accountKey = 'account_id';
const String _lastUrlKey = 'last_url';
const String _awayKey = 'server_url';
const String _homeKey = 'home_url';
const String _extraKey = 'extra_urls';
const Duration _scanEvery = Duration(seconds: 30);
const Duration _poolRefreshEvery = Duration(seconds: 20);
const String _modeKey = 'route_mode';
const String _userKey = 'username';
const String _passwordKey = 'password';
const String _topologyKey = 'server_topology';

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

const _tunnelTimeout = Duration(seconds: 20);

/// A tunnel that was working a moment ago answers quickly or not at all, so checking
/// it doesn't need the long wait a freshly started one does.
const Duration _tunnelHealthTimeout = Duration(seconds: 6);

Future<ProbeResult> _probeTunnel(String url, String user, String password) =>
    probeUrl(url, user, password, timeout: _tunnelTimeout);

/// Holds the signed-in account and the clients built from it. With a home and an away
/// address saved, it checks which one works and switches by itself when the network changes.
class SessionController extends ChangeNotifier with WidgetsBindingObserver {
  SessionController({
    ServerPool? pool,
    VaultStorage? storage,
    ConnectivityController? connectivity,
    HomeProbe? probe,
    UrlProbe? urlProbe,
    LanFinder? lanFinder,
    this.tunnelConnect,
    this.tunnelResolve,
    this.tunnelReconnect,
    this.tunnelNetworkChanged,
    UrlProbe? tunnelProbe,
    this.uploadPortFor,
    RoleProbe? roleProbe,
    this.catalogCacheFor,
    this.outboxFor,
    http.Client? httpClient,
    this.migratePersonalServers = const bool.fromEnvironment(
      'YOMI_MIGRATE_PERSONAL_SERVERS',
    ),
  }) : pool = pool ?? ServerPool(),
       _httpClient = httpClient,
       _roleProbe = roleProbe ?? probeIsReplica,
       _storage =
           storage ??
           VaultStorage(
             const FlutterSecureStorage(
               // The login Keychain works for locally built Mac apps without a
               // provisioning profile; credentials still stay in Apple's Keychain.
               mOptions: MacOsOptions(usesDataProtectionKeychain: false),
             ),
             legacyKeys: _secureKeys,
             // One Keychain item, so a Mac asks for its password once, not once
             // per saved setting.
             isVaultOn: Platform.isMacOS,
           ),
       _connectivity = connectivity,
       _probe = probe ?? _pingProbe,
       _urlProbe = urlProbe ?? probeUrl,
       _tunnelProbe = tunnelProbe ?? urlProbe ?? _probeTunnel,
       _lanFinder = lanFinder ?? findServerOnLan {
    _connectivity?.addListener(_onNetworkChanged);
  }

  /// Opens the saved server data for an account. Without it nothing is saved.
  final CatalogCache Function(String accountId)? catalogCacheFor;
  CatalogCache? _catalogCache;

  /// Opens the saved changes waiting to reach the server for an account.
  final Outbox Function(String accountId)? outboxFor;
  Outbox? _outbox;
  String? _accountId;

  /// Stays the same however the server is reached, until sign-out.
  String? get accountId => _accountId;

  /// Removes account-bound external registrations before credentials are cleared.
  Future<void> Function()? beforeSignOut;
  int _epoch = 0;
  bool _isSigningOut = false;
  bool _valid(int epoch) => epoch == _epoch && !_isSigningOut;

  /// Every known server with its health and load, shared with the download and preload
  /// code so they can spread transfers across all of them.
  final ServerPool pool;
  bool _isRefreshingPool = false;
  DateTime? _poolCheckedAt;

  /// Checks every known address at once and tells [pool] which answer and how fast.
  /// Throttled, so calling it after each route check costs nothing extra.
  Future<void> refreshPool({bool force = false}) async {
    final epoch = _epoch;
    if (_isRefreshingPool || _client == null || _isSigningOut) return;
    final last = _poolCheckedAt;
    if (!force &&
        last != null &&
        DateTime.now().difference(last) < _poolRefreshEvery) {
      return;
    }
    _isRefreshingPool = true;
    try {
      final urls = candidateUrls;
      pool.setServers(urls);
      await Future.wait(
        urls.map((url) async {
          final result = await _probeAddress(url, _user, _password);
          if (!_valid(epoch)) return;
          if (result.isOk) {
            pool.setRoute(url, _resolvedUrls[url]);
            pool.recordSuccess(url, result.elapsed);
          } else {
            pool.recordFailure(url);
          }
        }),
      );
      _poolCheckedAt = DateTime.now();
    } finally {
      _isRefreshingPool = false;
    }
  }

  final http.Client? _httpClient;
  final VaultStorage _storage;
  final ConnectivityController? _connectivity;
  final HomeProbe _probe;
  final UrlProbe _urlProbe;
  final UrlProbe _tunnelProbe;
  final LanFinder _lanFinder;

  /// Starts the embedded tunnel and returns its address, if this device has joined.
  final Future<String?> Function()? tunnelConnect;
  final Future<String?> Function(String url)? tunnelResolve;
  final Map<String, String> _resolvedUrls = {};

  Future<ProbeResult> _probeAddress(
    String url,
    String user,
    String password,
  ) async {
    final direct = await _urlProbe(url, user, password);
    if (direct.isOk) {
      _resolvedUrls.remove(url);
      return direct;
    }
    final local = await tunnelResolve?.call(url);
    if (local == null) return direct;
    final result = await _tunnelProbe(local, user, password);
    if (result.isOk) _resolvedUrls[url] = local;
    return ProbeResult(
      url: url,
      isOk: result.isOk,
      elapsed: result.elapsed,
      problem: result.problem,
    );
  }

  final Future<String?> Function()? tunnelReconnect;
  final Future<void> Function()? tunnelNetworkChanged;

  /// The upload service's port for an address; it differs when going through the tunnel.
  final int Function(String url)? uploadPortFor;
  final RoleProbe _roleProbe;
  final bool migratePersonalServers;
  bool _isOnTunnel = false;
  bool _isOnReplica = false;
  Timer? _primaryRetry;
  Timer? _roleRetry;
  bool _isScanning = false;
  DateTime? _lastScan;
  List<String> _extraUrls = const [];
  bool _isOnBackup = false;

  SubsonicClient? _client;
  UploadTransport? _uploader;
  String? _awayUrl;
  String? _homeUrl;
  String _user = '';
  String _password = '';
  RouteMode _mode = RouteMode.auto;
  ActiveRoute _route = ActiveRoute.away;
  bool _isRestoring = true;
  bool _isResolving = false;
  WidgetsBinding? _binding;

  void startMonitoring() {
    _binding ??= WidgetsBinding.instance;
    _binding!.addObserver(this);
    _routeRefresh = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_client != null && _mode == RouteMode.auto && _isActive) {
        _onNetworkChanged();
      }
    });
    // Servers can come and go while one stays in use, so keep the pool's view fresh.
    _poolRefresh = Timer.periodic(_poolRefreshEvery, (_) {
      if (candidateUrls.length > 1 && _isActive) unawaited(refreshPool());
    });
  }

  /// Says whether the route still matters while the app is off screen, such as when
  /// music is playing. Without it, checks stop until the app is opened again.
  bool Function()? isNeededInBackground;

  bool get _isActive =>
      _binding?.lifecycleState == AppLifecycleState.resumed ||
      (isNeededInBackground?.call() ?? false);

  Timer? _poolRefresh;
  Timer? _routeRefresh;
  Timer? _debounce;
  Timer? _reachRetry;
  bool _isServerReachable = true;
  bool _isChecking = false;
  bool _checkPending = false;

  /// False once a quick check fails; the app then shows the offline screen and keeps retrying.
  bool get isServerReachable => _isServerReachable;
  bool get isChecking => _isChecking;

  /// Extra addresses tried, in order, when the main ones don't answer.
  List<String> get extraUrls => List.unmodifiable(_extraUrls);
  bool get isOnBackup => _isOnBackup;
  bool get isOnTunnel => _isOnTunnel;

  /// On the read-only backup server: edits are refused and plays wait for the main one.
  bool get isOnReplica => _isOnReplica;
  int get uploadServicePort => _uploadPort(serverUrl);

  int _uploadPort(String url) => uploadPortFor?.call(url) ?? uploadPort;

  /// Every address Yomi knows, best first, without repeats.
  List<String> get candidateUrls => {
    if (_homeUrl != null) _homeUrl!,
    if (_awayUrl != null) _awayUrl!,
    ..._extraUrls,
  }.toList();

  bool get isRestoring => _isRestoring;
  bool get isSignedIn => _client != null;
  SubsonicClient get client => _client!;
  UploadTransport get uploader => _uploader!;
  MessagingTransport get messaging =>
      MessagingApi(serverUrl: serverUrl, auth: client, port: uploadServicePort);
  String get username => _user;
  String get serverUrl => _client?.baseUrl ?? '';
  String get awayUrl => _awayUrl ?? '';
  String get homeUrl => _homeUrl ?? '';
  RouteMode get mode => _mode;
  ActiveRoute get route => _route;
  bool get isResolving => _isResolving;
  bool get hasHomeAddress => (_homeUrl ?? '').isNotEmpty;

  String get routeLabel => _isOnReplica
      ? 'Backup server'
      : _isOnTunnel
      ? 'Invite tunnel'
      : _isOnBackup
      ? 'Backup address'
      : switch (_route) {
          ActiveRoute.home => 'Home network',
          ActiveRoute.away => hasHomeAddress ? 'Away from home' : 'Connected',
        };

  /// Restores the session and works out the best route. See [restoreSaved].
  Future<void> restore() async {
    await restoreSaved();
    await resolveRoute();
  }

  /// Signs back in from what's saved, without touching the network, so the app can show
  /// real content while [resolveRoute] finds the best address behind it.
  Future<void> restoreSaved() async {
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
        var migrated = false;
        if (migratePersonalServers &&
            defaultServerUrl == cloudMusicUrl &&
            await _storage.read(key: _topologyKey) != cloudTopologyVersion) {
          final topology = migrateCloudTopology(
            away: normalizeServerUrl(away),
            home: _homeUrl,
            extras: _extraUrls,
          );
          if (topology != null) {
            _awayUrl = topology.away;
            _homeUrl = topology.home;
            _extraUrls = topology.extras;
            await _storage.write(key: _awayKey, value: _awayUrl);
            await _storage.write(key: _homeKey, value: _homeUrl);
            await _storage.write(key: _extraKey, value: jsonEncode(_extraUrls));
            await _storage.write(
              key: _topologyKey,
              value: cloudTopologyVersion,
            );
            migrated = true;
          }
        }
        // Signed in to the cloud before backups were built in: add the standby once.
        // Afterwards the list is the user's own, so removing it sticks.
        if (!migrated &&
            await _storage.read(key: _topologyKey) != cloudTopologyVersion) {
          final seeded = withDefaultBackup(
            away: _awayUrl!,
            home: _homeUrl,
            extras: _extraUrls,
          );
          if (seeded.length != _extraUrls.length) {
            _extraUrls = seeded;
            await _storage.write(key: _extraKey, value: jsonEncode(_extraUrls));
          }
          if (_awayUrl == cloudMusicUrl) await _markTopology();
        }
        await _openAccount();
        final lastUrl = await _storage.read(key: _lastUrlKey);
        final url = !migrated && candidateUrls.contains(lastUrl)
            ? lastUrl!
            : _awayUrl!;
        _route = url == _homeUrl ? ActiveRoute.home : ActiveRoute.away;
        _isOnBackup = url != _homeUrl && url != _awayUrl;
        _build(url);
      }
    } on Exception catch (error) {
      debugPrint('Could not restore session: $error');
    } finally {
      _isRestoring = false;
      notifyListeners();
    }
  }

  /// Checks the route and the server after [restoreSaved].
  Future<void> resolveRoute() async {
    if (_client == null) return;
    try {
      await refreshRoute();
    } on Exception catch (error) {
      debugPrint('Could not choose a route: $error');
    }
    if (_client != null) unawaited(checkServer());
  }

  /// Finds this account's saved ID, or creates one, and opens its saved data.
  Future<void> _openAccount() async {
    var id = await _storage.read(key: _accountKey);
    if (id == null) {
      final random = Random.secure();
      id = List.generate(
        16,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      await _storage.write(key: _accountKey, value: id);
    }
    _accountId = id;
    final cache = catalogCacheFor?.call(id);
    await cache?.load();
    _catalogCache = cache;
    final outbox = outboxFor?.call(id);
    await outbox?.load();
    _outbox = outbox;
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
    String? tunnelUrl;
    if (!homeWorks) {
      try {
        await SubsonicClient(
          baseUrl: away,
          username: user.trim(),
          password: password,
          httpClient: _httpClient,
        ).ping();
      } on SubsonicException catch (error) {
        if (error.kind != ErrorKind.unreachable) rethrow;
        tunnelUrl = await tunnelConnect?.call();
        if (tunnelUrl == null) rethrow;
        await SubsonicClient(
          baseUrl: tunnelUrl,
          username: user.trim(),
          password: password,
          httpClient: _httpClient,
        ).ping(timeout: _tunnelTimeout);
      }
    }
    _awayUrl = away;
    _homeUrl = home.isEmpty ? null : home;
    _mode = RouteMode.auto;
    _user = user.trim();
    _password = password;
    _extraUrls = withDefaultBackup(
      away: away,
      home: _homeUrl,
      extras: _extraUrls,
    );
    await _remember();
    await _markTopology();
    await _openAccount();
    _route = homeWorks ? ActiveRoute.home : ActiveRoute.away;
    _isOnTunnel = tunnelUrl != null;
    _build(homeWorks ? home : (tunnelUrl ?? away));
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
    // The route check trusts the away address without trying it; this does try it,
    // and moves to a backup at once if it doesn't answer.
    _checkNow();
  }

  /// Decides between home and away: on home Wi-Fi it probes the home address quickly,
  /// anywhere else it uses the away address. Safe to call often.
  Future<void> refreshRoute() async {
    final epoch = _epoch;
    if (_isSigningOut || _client == null || _isResolving) return;
    _isResolving = true;
    notifyListeners();
    try {
      final chosen = await _chooseRoute();
      if (!_valid(epoch)) return;
      // The tunnel exists because the away address failed, so it isn't undone by
      // merely choosing "away" again. Only home, or a failed check, moves off it.
      if (_isOnTunnel && !_isOnBackup && chosen == ActiveRoute.away) return;
      // A backup address took over because the away address failed. Move back only once
      // the away address answers, or each check would bounce between the two.
      if (_isOnBackup && chosen == ActiveRoute.away) {
        final away = _awayUrl ?? _homeUrl!;
        if (!(await _probeAddress(away, _user, _password)).isOk ||
            !_valid(epoch))
          return;
      }
      _isOnTunnel = false;
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
    final epoch = _epoch;
    final client = _client;
    if (_isSigningOut || client == null || _isChecking) return;
    _isChecking = true;
    notifyListeners();
    var reachable = false;
    try {
      await client.ping(
        timeout: _isOnTunnel ? _tunnelHealthTimeout : _reachTimeout,
      );
      reachable = true;
    } on Exception {
      if (!_valid(epoch)) return;
      try {
        reachable = await _failOver(client.baseUrl);
      } on Exception catch (error) {
        debugPrint('Server recovery failed: $error');
      }
    } finally {
      _isChecking = false;
      if (_checkPending) {
        _checkPending = false;
        scheduleMicrotask(checkServer);
      }
    }
    if (!_valid(epoch)) return;
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
  Future<bool> _failOver(String deadUrl, {bool retryTunnel = true}) async {
    final epoch = _epoch;
    // A direct failure does not mean the same server is unreachable through
    // the embedded node. Try it before falling back to a read-only peer.
    final others = [
      if (candidateUrls.contains(deadUrl)) deadUrl,
      ...candidateUrls.where((u) => u != deadUrl),
    ];
    final working = await _firstWorking(others);
    if (!_valid(epoch)) return false;
    if (working != null) {
      final url = working.url;
      _isOnBackup = url != _homeUrl && url != _awayUrl;
      _route = url == _homeUrl ? ActiveRoute.home : ActiveRoute.away;
      _isOnTunnel = false;
      _build(url);
      return true;
    }
    // Restart the shared node only after every peer failed. A dead primary must
    // never tear down a working backup during doctor or primary-return checks.
    if (retryTunnel && tunnelResolve != null && tunnelReconnect != null) {
      await tunnelReconnect!();
      if (!_valid(epoch)) return false;
      _resolvedUrls.clear();
      return _failOver(deadUrl, retryTunnel: false);
    }
    return _connectThroughTunnel();
  }

  /// Probes [urls] at once and returns the best one that answers, or null. The best is
  /// the earliest in the list, but once any address answers the ones ahead of it only
  /// get [_failoverGrace] longer, so a dead main server can't hold up a live backup.
  Future<ProbeResult?> _firstWorking(List<String> urls) {
    if (urls.isEmpty) return Future.value();
    final done = Completer<ProbeResult?>();
    final results = List<ProbeResult?>.filled(urls.length, null);
    Timer? grace;
    ProbeResult? best() {
      for (final result in results) {
        if (result != null && result.isOk) return result;
      }
      return null;
    }

    void finish() {
      grace?.cancel();
      if (!done.isCompleted) done.complete(best());
    }

    for (var i = 0; i < urls.length; i++) {
      unawaited(
        _probeAddress(urls[i], _user, _password).then((result) {
          if (done.isCompleted) return;
          results[i] = result;
          final firstOk = results.indexWhere((r) => r != null && r.isOk);
          final isSettled = firstOk < 0
              ? !results.contains(null)
              : !results.take(firstOk).contains(null);
          if (isSettled) return finish();
          if (firstOk >= 0) grace ??= Timer(_failoverGrace, finish);
        }),
      );
    }
    return done.future;
  }

  /// Last resort after every direct address failed, so a device that can reach the
  /// server by LAN or the Tailscale app never pays for a second network stack.
  Future<bool> _connectThroughTunnel() async {
    final epoch = _epoch;
    // Already on the tunnel and it stopped answering: start it over right away. The
    // node may still claim to be running after the phone suspended it.
    final wasOnTunnel = _isOnTunnel;
    var url = wasOnTunnel
        ? await tunnelReconnect?.call()
        : await tunnelConnect?.call();
    if (url == null || !_valid(epoch)) return false;
    var result = await _tunnelProbe(url, _user, _password);
    if (!_valid(epoch)) return false;
    if (!result.isOk && wasOnTunnel) return false;
    if (!result.isOk) {
      // Running only describes the backend, not whether its peer path works.
      url = await tunnelReconnect?.call();
      if (url == null || !_valid(epoch)) return false;
      result = await _tunnelProbe(url, _user, _password);
      if (!result.isOk || !_valid(epoch)) return false;
    }
    _isOnBackup = false;
    _isOnTunnel = true;
    _build(url);
    return true;
  }

  /// Tries every known address and reports how each one did. Used by the Connection doctor.
  Future<List<ProbeResult>> diagnose() => diagnoseUrls(candidateUrls);

  /// Addresses never typed in, made by mixing the known schemes, hosts and ports (and
  /// [extraHosts], the other machines that serve the library). The doctor tries them too.
  List<String> suggestedUrls({List<String>? extraHosts}) => addressCombinations(
    candidateUrls,
    extraHosts: extraHosts ?? defaultExtraHosts,
  );

  /// Checks [urls] all at once, in the same order.
  Future<List<ProbeResult>> diagnoseUrls(List<String> urls) =>
      Future.wait(urls.map((u) => _probeAddress(u, _user, _password)));

  /// Switches to [url] by hand, e.g. from the doctor, after it answered.
  void useUrl(String url) {
    if (_client == null) return;
    _isOnBackup = url != _awayUrl && url != _homeUrl;
    _isOnTunnel = false;
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
    unawaited(refreshPool(force: true));
    // A backup is usually added because nothing else answers, so use it straight away
    // rather than at the next retry.
    if (!_isServerReachable) _checkNow();
  }

  /// Runs the reachability check now, or right after the one already running.
  void _checkNow() {
    _reachRetry?.cancel();
    if (_isChecking) {
      _checkPending = true;
    } else {
      unawaited(checkServer());
    }
  }

  Future<void> removeExtraUrl(String url) async {
    _extraUrls = _extraUrls.where((u) => u != url).toList();
    await _remember();
    notifyListeners();
    unawaited(refreshPool(force: true));
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
    if (!hasHomeAddress) {
      if (_mode == RouteMode.auto) unawaited(_healHome());
      return ActiveRoute.away;
    }
    return switch (_mode) {
      RouteMode.home => ActiveRoute.home,
      RouteMode.away => ActiveRoute.away,
      RouteMode.auto => await _autoRoute(),
    };
  }

  Future<ActiveRoute> _autoRoute() async {
    final epoch = _epoch;
    // Off Wi-Fi there is no way to be on the home network, so skip the probe.
    if (_connectivity != null && !_connectivity.isOnWifi)
      return ActiveRoute.away;
    if (await _probe(_homeUrl!, _user, _password)) return ActiveRoute.home;
    if (!_valid(epoch)) return ActiveRoute.away;
    // Already home: one slow answer, often just after wake, isn't a reason to leave.
    if (_route == ActiveRoute.home &&
        await _probe(_homeUrl!, _user, _password)) {
      return ActiveRoute.home;
    }
    unawaited(_healHome());
    return ActiveRoute.away;
  }

  /// The saved home address stopped answering, usually because the router handed the server
  /// a new IP. Looks for it on this Wi-Fi and, if found, saves it as the new home address.
  Future<void> _healHome() async {
    final epoch = _epoch;
    final last = _lastScan;
    final isRecent =
        last != null && DateTime.now().difference(last) < _scanEvery;
    final isOnOtherNetwork = _connectivity != null && !_connectivity.isOnWifi;
    if (_isScanning || isRecent || isOnOtherNetwork || _client == null) return;
    _isScanning = true;
    _lastScan = DateTime.now();
    try {
      final found = await _lanFinder(_user, _password);
      if (found == null || _client == null || !_valid(epoch)) return;
      final isNew = found != _homeUrl;
      _homeUrl = found;
      if (isNew) await _remember();
      if (!_valid(epoch)) return;
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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _onNetworkChanged();
  }

  void _onNetworkChanged() {
    _debounce?.cancel();
    _debounce = Timer(_routeDebounce, () async {
      await tunnelNetworkChanged?.call();
      await refreshRoute();
      await _routineCheck();
    });
  }

  /// A check nobody is waiting on. Only when it keeps failing does the full check run,
  /// which may change the route or show the app as offline.
  Future<void> _routineCheck() async {
    final epoch = _epoch;
    final client = _client;
    if (client == null) return;
    // A suspended tunnel won't wake by waiting, so it gets one quick look, then the
    // full check restarts it.
    final attempts = _isOnTunnel ? 1 : _routineAttempts;
    for (var attempt = 0; attempt < attempts; attempt++) {
      try {
        await client.ping(
          timeout: _isOnTunnel ? _tunnelHealthTimeout : _wakeTimeout,
        );
        if (!_valid(epoch)) return;
        if (!_isServerReachable) {
          _reachRetry?.cancel();
          _isServerReachable = true;
          notifyListeners();
        }
        return;
      } on Exception catch (error) {
        debugPrint('Routine server check failed: $error');
      }
    }
    if (_valid(epoch)) await checkServer();
  }

  Future<void> signOut() async {
    _epoch++;
    _isSigningOut = true;
    try {
      await beforeSignOut?.call();
    } on Object catch (error) {
      debugPrint('Could not remove account registration: $error');
    }
    final cache = _catalogCache;
    _catalogCache = null;
    _accountId = null;
    await cache?.clear();
    final outbox = _outbox;
    _outbox = null;
    await outbox?.clear();
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
    _resolvedUrls.clear();
    _isOnBackup = false;
    _user = '';
    _password = '';
    _isSigningOut = false;
    _primaryRetry?.cancel();
    _roleRetry?.cancel();
    _debounce?.cancel();
    notifyListeners();
  }

  Future<void> _markTopology() async {
    if (_awayUrl != cloudMusicUrl) return;
    try {
      await _storage.write(key: _topologyKey, value: cloudTopologyVersion);
    } on Exception catch (error) {
      debugPrint('Could not save the server layout version: $error');
    }
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
    final logicalUrl = url;
    if (_resolvedUrls.containsKey(url)) _isOnTunnel = true;
    url = _resolvedUrls[url] ?? url;
    _client = SubsonicClient(
      baseUrl: url,
      username: _user,
      password: _password,
      isReadOnly: () => _isOnReplica,
      cache: _catalogCache,
      outbox: _outbox,
      httpClient: _httpClient,
    );
    unawaited(_rememberUrl(logicalUrl));
    unawaited(_refreshRole(url));
    _uploader = BulkUploadApi(
      serverUrl: url,
      auth: _client!,
      port: _uploadPort(url),
    );
  }

  Future<void> _rememberUrl(String url) async {
    try {
      await _storage.write(key: _lastUrlKey, value: url);
    } on Exception catch (error) {
      debugPrint('Could not save the last address: $error');
    }
  }

  Future<void> _refreshRole(String url) async {
    final isReplica = await _roleProbe(url, _uploadPort(url));
    if (url != serverUrl) return; // Moved on while this was being asked.
    _roleRetry?.cancel();
    if (isReplica == null) {
      // Couldn't tell, so keep what was known and ask again shortly.
      _roleRetry = Timer(_roleRetryAfter, () => unawaited(_refreshRole(url)));
      return;
    }
    if (isReplica != _isOnReplica) {
      _isOnReplica = isReplica;
      notifyListeners();
    }
    _primaryRetry?.cancel();
    if (isReplica) {
      _primaryRetry = Timer.periodic(_primaryRetryEvery, (_) {
        unawaited(returnToPrimary());
      });
    }
  }

  /// Moves back once a non-backup address answers again. The player stays on the
  /// current song until it ends, so nothing audibly changes.
  Future<void> returnToPrimary() async {
    final epoch = _epoch;
    if (_isSigningOut || !_isOnReplica) return;
    for (final url in candidateUrls) {
      if (url == serverUrl) continue;
      final result = await _probeAddress(url, _user, _password);
      if (!_valid(epoch)) return;
      if (!result.isOk) continue;
      final resolved = _resolvedUrls[url] ?? url;
      if (await _roleProbe(resolved, _uploadPort(resolved)) != false) continue;
      if (!_valid(epoch)) return;
      _isOnReplica = false;
      _isOnBackup = url != _awayUrl && url != _homeUrl;
      _isOnTunnel = false;
      _route = url == _homeUrl ? ActiveRoute.home : ActiveRoute.away;
      _primaryRetry?.cancel();
      _build(url);
      notifyListeners();
      return;
    }
  }

  @override
  void dispose() {
    _epoch++;
    _binding?.removeObserver(this);
    _routeRefresh?.cancel();
    _poolRefresh?.cancel();
    _primaryRetry?.cancel();
    _roleRetry?.cancel();
    _debounce?.cancel();
    _reachRetry?.cancel();
    _connectivity?.removeListener(_onNetworkChanged);
    super.dispose();
  }
}
