import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/session.dart';
import '../theme.dart';

enum _Status { queued, uploading, done, failed }

class _UploadItem {
  const _UploadItem({
    required this.name,
    required this.path,
    this.status = _Status.queued,
    this.progress = 0,
    this.error,
  });

  final String name;
  final String path;
  final _Status status;
  final double progress;
  final String? error;

  _UploadItem copyWith({_Status? status, double? progress, String? error}) =>
      _UploadItem(
        name: name,
        path: path,
        status: status ?? this.status,
        progress: progress ?? this.progress,
        error: error ?? this.error,
      );
}

class UploadPage extends StatefulWidget {
  const UploadPage({super.key});

  @override
  State<UploadPage> createState() => _UploadPageState();
}

class _UploadPageState extends State<UploadPage> {
  List<_UploadItem> _items = const [];
  bool _isRunning = false;

  void _update(int index, _UploadItem Function(_UploadItem) change) {
    if (!mounted) return;
    setState(
      () => _items = [
        for (var i = 0; i < _items.length; i++)
          i == index ? change(_items[i]) : _items[i],
      ],
    );
  }

  Future<void> _pickAndUpload() async {
    final picked = await FilePicker.pickFiles(type: FileType.audio);
    final fresh = [
      for (final file in picked)
        if (file.path != null) _UploadItem(name: file.name, path: file.path!),
    ];
    if (fresh.isEmpty || !mounted) return;
    final firstNew = _items.length;
    setState(() => _items = [..._items, ...fresh]);
    if (!_isRunning) await _runQueue(firstNew);
  }

  Future<void> _runQueue(int from) async {
    final uploader = context.read<SessionController>().uploader;
    setState(() => _isRunning = true);
    for (var i = from; i < _items.length; i++) {
      if (_items[i].status != _Status.queued) continue;
      _update(i, (item) => item.copyWith(status: _Status.uploading));
      try {
        await uploader.upload(
          File(_items[i].path),
          onProgress: (p) => _update(i, (item) => item.copyWith(progress: p)),
        );
        _update(i, (item) => item.copyWith(status: _Status.done, progress: 1));
      } on Exception catch (error) {
        _update(
          i,
          (item) => item.copyWith(status: _Status.failed, error: '$error'),
        );
      }
    }
    if (mounted) setState(() => _isRunning = false);
  }

  Future<void> _retryFailed() async {
    setState(
      () => _items = [
        for (final item in _items)
          item.status == _Status.failed
              ? item.copyWith(status: _Status.queued, progress: 0)
              : item,
      ],
    );
    if (!_isRunning) await _runQueue(0);
  }

  @override
  Widget build(BuildContext context) {
    final doneCount = _items.where((i) => i.status == _Status.done).length;
    final hasFailures = _items.any((i) => i.status == _Status.failed);
    return SafeArea(
      bottom: false,
      child: ListView(
        padding: EdgeInsets.fromLTRB(
          kPagePadding,
          0,
          kPagePadding,
          MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 22, bottom: 8),
            child: Text(
              'Add songs',
              style: yomiText(36, weight: FontWeight.w800, letterSpacing: -1),
            ),
          ),
          const SizedBox(height: 18),
          GestureDetector(
            onTap: _pickAndUpload,
            child: Container(
              height: 150,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(26),
                gradient: LinearGradient(
                  colors: [
                    context.accentDeep.withValues(alpha: 0.35),
                    context.accentSecondary.withValues(alpha: 0.18),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                border: Border.all(
                  color: context.accent.withValues(alpha: 0.35),
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.upload_rounded, size: 40, color: context.accent),
                  const SizedBox(height: 10),
                  Text(
                    _isRunning ? 'Add more songs' : 'Choose songs',
                    style: yomiText(17, weight: FontWeight.w800),
                  ),
                  Text(
                    'mp3, m4a, flac, ogg, opus, wav',
                    style: yomiText(
                      12.5,
                      weight: FontWeight.w500,
                      color: YomiColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_items.isNotEmpty) ...[
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '$doneCount of ${_items.length} uploaded',
                    style: yomiText(15, weight: FontWeight.w800),
                  ),
                ),
                if (hasFailures && !_isRunning)
                  TextButton(
                    onPressed: _retryFailed,
                    child: const Text('Retry failed'),
                  ),
                if (!_isRunning)
                  TextButton(
                    onPressed: () => setState(() => _items = const []),
                    child: const Text('Clear'),
                  ),
              ],
            ),
            for (final item in _items) _UploadRow(item: item),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _UploadRow extends StatelessWidget {
  const _UploadRow({required this.item});

  final _UploadItem item;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (item.status) {
      _Status.queued => (Icons.schedule_rounded, YomiColors.textSecondary),
      _Status.uploading => (Icons.cloud_upload_rounded, context.accent),
      _Status.done => (Icons.check_circle_rounded, Colors.greenAccent),
      _Status.failed => (Icons.error_rounded, Colors.redAccent),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: yomiText(14.5, weight: FontWeight.w600),
                ),
                if (item.status == _Status.uploading)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: LinearProgressIndicator(
                      value: item.progress,
                      minHeight: 3,
                      color: context.accent,
                      backgroundColor: YomiColors.surfaceHigh,
                    ),
                  ),
                if (item.status == _Status.failed)
                  Text(
                    item.error ?? 'Failed',
                    style: const TextStyle(
                      color: Colors.redAccent,
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
