import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// A change waiting to reach the server.
@immutable
class OutboxItem {
  const OutboxItem(this.endpoint, this.params);

  final String endpoint;
  final Map<String, Object?> params;

  Map<String, Object?> toJson() => {'endpoint': endpoint, 'params': params};
}

/// Changes made while the server couldn't be reached, saved so they survive a restart and
/// are sent in order when it's back.
class Outbox {
  Outbox(this._file);

  final File _file;
  List<OutboxItem> _items = const [];
  Future<void>? _loading;
  Future<void> _writes = Future.value();

  List<OutboxItem> get items => _items;

  Future<void> load() => _loading ??= _read();

  Future<void> _read() async {
    try {
      if (!await _file.exists()) return;
      final json = jsonDecode(await _file.readAsString()) as List<dynamic>;
      _items = List.unmodifiable(
        json.cast<Map<String, dynamic>>().map(
          (item) => OutboxItem(
            item['endpoint'] as String,
            Map<String, Object?>.from(item['params'] as Map),
          ),
        ),
      );
    } on Object catch (error) {
      debugPrint('Ignoring an unreadable outbox: $error');
    }
  }

  Future<void> add(OutboxItem item) {
    _items = List.unmodifiable([..._items, item]);
    return _save();
  }

  Future<void> removeFirst() {
    _items = List.unmodifiable(_items.skip(1));
    return _save();
  }

  Future<void> clear() async {
    _items = const [];
    await _writes;
    try {
      if (await _file.exists()) await _file.delete();
    } on FileSystemException catch (error) {
      debugPrint('Could not delete the outbox: $error');
    }
  }

  Future<void> _save() => _writes = _writes.then((_) async {
    try {
      final temp = File('${_file.path}.tmp');
      await temp.parent.create(recursive: true);
      await temp.writeAsString(
        jsonEncode([for (final item in _items) item.toJson()]),
      );
      await temp.rename(_file.path);
    } on Object catch (error) {
      debugPrint('Could not save the outbox: $error');
    }
  });
}
