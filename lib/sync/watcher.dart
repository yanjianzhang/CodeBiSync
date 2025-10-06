import 'dart:async';

abstract class Watcher {
  /// 等待直到有文件系统变更或超时（例如每 N 毫秒强制触发一次同步）
  Future<void> waitForChangeOrTimeout();

  /// 可选：立即触发一个通知（例如手动 flush）
  void trigger();
}
