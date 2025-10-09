import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../watcher.dart';

class FsWatcher implements Watcher {
  final String root;
  final Duration maxInterval;
  final Duration debounce;
  final int maxBatchSize;

  final Set<String> _pending = <String>{};
  bool _needsFullRescan = false;

  Completer<void>? _pendingSignal;
  Timer? _timeoutTimer;
  Timer? _debounceTimer;
  StreamSubscription<FileSystemEvent>? _subscription;

  late final String _rootCanonical;
  late final String _rootWithSep;

  FsWatcher({
    required this.root,
    this.maxInterval = const Duration(seconds: 5),
    this.debounce = const Duration(milliseconds: 200),
    this.maxBatchSize = 256,
  }) {
    _rootCanonical = _normalizeRoot(root);
    _rootWithSep = _ensureTrailingSeparator(_rootCanonical);
    final dir = Directory(_rootCanonical);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    _subscription = dir.watch(recursive: true).listen(_handleEvent, onError: _handleError);
  }

  static String _normalizeRoot(String input) {
    final dir = Directory(input).absolute.path;
    return p.normalize(dir);
  }

  static String _ensureTrailingSeparator(String input) {
    return input.endsWith(p.separator) ? input : '$input${p.separator}';
  }

  @override
  Future<void> waitForChangeOrTimeout() async {
    if (_needsFullRescan || _pending.isNotEmpty) {
      return;
    }
    _pendingSignal ??= Completer<void>();
    _timeoutTimer?.cancel();
    _timeoutTimer = Timer(maxInterval, _completeNow);
    await _pendingSignal!.future;
  }

  @override
  void trigger() {
    _needsFullRescan = true;
    _completeNow();
  }

  @override
  WatchEventBatch drainChanges() {
    final requiresFull = _needsFullRescan;
    _needsFullRescan = false;
    final result = requiresFull ? <String>{} : Set<String>.from(_pending);
    _pending.clear();
    _clearTimers();
    return WatchEventBatch(requiresFullRescan: requiresFull, paths: result);
  }

  void _handleEvent(FileSystemEvent event) {
    final rel = _relativeFromRoot(event.path);
    if (rel == null) {
      _needsFullRescan = true;
      _completeAfterDebounce();
      return;
    }
    _markPath(rel);

    if (event is FileSystemMoveEvent) {
      final dest = event.destination;
      if (dest != null) {
        final destRel = _relativeFromRoot(dest);
        if (destRel != null) {
          _markPath(destRel);
        } else {
          _needsFullRescan = true;
        }
      } else {
        _needsFullRescan = true;
      }
    }

    _completeAfterDebounce();
  }

  void _handleError(Object error) {
    _needsFullRescan = true;
    _completeAfterDebounce();
  }

  void _markPath(String rel) {
    if (rel.isEmpty) {
      _needsFullRescan = true;
      return;
    }
    _pending.add(rel);

    final parent = _parentOf(rel);
    if (parent != null && parent.isNotEmpty) {
      _pending.add(parent);
    }

    if (_pending.length > maxBatchSize) {
      _needsFullRescan = true;
    }
  }

  String? _parentOf(String rel) {
    final parent = p.dirname(rel);
    if (parent == '.' || parent.isEmpty) {
      return '';
    }
    if (parent.startsWith('..')) {
      return null;
    }
    return parent;
  }

  String? _relativeFromRoot(String fullPath) {
    try {
      final normalized = p.normalize(fullPath);
      if (normalized == _rootCanonical) return '';
      if (!normalized.startsWith(_rootWithSep)) return null;
      final rel = p.relative(normalized, from: _rootCanonical);
      if (rel.startsWith('..')) {
        return null;
      }
      return rel;
    } catch (_) {
      return null;
    }
  }

  void _completeAfterDebounce() {
    if (_pendingSignal == null) {
      return;
    }
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, _completeNow);
  }

  void _completeNow() {
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _pendingSignal?.complete();
    _pendingSignal = null;
  }

  void _clearTimers() {
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _pendingSignal = null;
  }
}
