import 'dart:async';

import '../watcher.dart';

class FsWatcher implements Watcher {
  final Duration interval;
  Completer<void>? _triggered;

  FsWatcher({this.interval = const Duration(seconds: 2)});

  @override
  void trigger() {
    _triggered?.complete();
  }

  @override
  Future<void> waitForChangeOrTimeout() async {
    _triggered = Completer<void>();
    await Future.any([
      Future.delayed(interval),
      _triggered!.future,
    ]);
  }
}

