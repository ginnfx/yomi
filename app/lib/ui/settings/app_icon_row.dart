import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AppIconRow extends StatefulWidget {
  const AppIconRow({super.key});
  @override
  State<AppIconRow> createState() => _AppIconRowState();
}

class _AppIconRowState extends State<AppIconRow> {
  static const _channel = MethodChannel('yomi/app_icon');
  String? _selected;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _channel
        .invokeMethod<String>('get')
        .then((value) {
          if (mounted) setState(() => _selected = value ?? 'Default');
        })
        .catchError((Object _) {});
  }

  Future<void> _set(String name) async {
    setState(() => _busy = true);
    try {
      await _channel.invokeMethod<void>('set', name);
      if (mounted) setState(() => _selected = name);
    } on PlatformException catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.message ?? 'Could not change icon')),
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!(Platform.isIOS || Platform.isMacOS || Platform.isAndroid) ||
        _selected == null)
      return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            Platform.isMacOS ? 'Dock icon' : 'App icon',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            children: [
              for (final name in ['Default', 'Midnight', 'Sakura'])
                ChoiceChip(
                  label: Text(name),
                  selected: name == _selected,
                  onSelected: _busy ? null : (_) => _set(name),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
