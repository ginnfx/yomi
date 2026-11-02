import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// What kind of network the phone is on right now.
class ConnectivityController extends ChangeNotifier {
  ConnectivityController({
    Stream<List<ConnectivityResult>>? changes,
    Future<List<ConnectivityResult>> Function()? check,
  }) : _check = check ?? (() => Connectivity().checkConnectivity()) {
    _subscription = (changes ?? Connectivity().onConnectivityChanged).listen(
      _update,
    );
    _check().then(_update);
  }

  final Future<List<ConnectivityResult>> Function() _check;
  late final StreamSubscription<List<ConnectivityResult>> _subscription;
  List<ConnectivityResult> _results = const [ConnectivityResult.wifi];

  bool get isOffline =>
      _results.isEmpty || _results.every((r) => r == ConnectivityResult.none);
  bool get isOnWifi =>
      _results.contains(ConnectivityResult.wifi) ||
      _results.contains(ConnectivityResult.ethernet);

  void _update(List<ConnectivityResult> results) {
    if (listEquals(results, _results)) return;
    _results = results;
    notifyListeners();
  }

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }
}
