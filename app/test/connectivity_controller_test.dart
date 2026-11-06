import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/state/connectivity_controller.dart';

void main() {
  test(
    'a computer without a network service stays online instead of crashing',
    () async {
      // Arrange
      final changes = StreamController<List<ConnectivityResult>>();
      addTearDown(changes.close);

      // Act
      final connectivity = ConnectivityController(
        changes: changes.stream,
        check: () => Future.error(StateError('no system bus')),
      );
      changes.addError(StateError('no system bus'));
      await pumpEventQueue();

      // Assert
      expect(connectivity.isOffline, isFalse);
      expect(connectivity.isOnWifi, isTrue);
    },
  );
}
