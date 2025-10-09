import 'dart:async';

abstract class Watcher {
  /// 等待直到有文件系统变更或超时（例如每 N 毫秒强制触发一次同步）
  Future<void> waitForChangeOrTimeout();

  /// 可选：立即触发一个通知（例如手动 flush）
  void trigger();

  /// 获取自上次消费以来收集到的变更集合。
  WatchEventBatch drainChanges();
}

class WatchEventBatch {
  final bool requiresFullRescan;
  final Set<String> paths;

  const WatchEventBatch({
    required this.requiresFullRescan,
    required this.paths,
  });

  factory WatchEventBatch.fullRescan() =>
      const WatchEventBatch(requiresFullRescan: true, paths: <String>{});
  factory WatchEventBatch.empty() =>
      const WatchEventBatch(requiresFullRescan: false, paths: <String>{});
}
