import 'dart:async';
import 'package:rxdart/rxdart.dart';

enum SyncOperation {
  scanFiles,
  uploadFile,
  downloadFile,
  verifyFile,
  createDirectory,
  deletePath,
  renamePath,
  detectChanges,
  verifyRemote
}

class SyncStatusEvent {
  final SyncOperation operation;
  final String details;
  final DateTime timestamp;
  final bool isComplete;

  SyncStatusEvent({
    required this.operation,
    required this.details,
    this.isComplete = false,
  }) : timestamp = DateTime.now();

  String get formattedMessage {
    switch (operation) {
      case SyncOperation.scanFiles:
        return isComplete ? '扫描文件完成' : '扫描文件中...';
      case SyncOperation.uploadFile:
        return isComplete ? '已上传: $details' : '正在上传: $details';
      case SyncOperation.downloadFile:
        return isComplete ? '已下载: $details' : '正在下载: $details';
      case SyncOperation.verifyFile:
        return isComplete ? '验证完成: $details' : '验证文件: $details';
      case SyncOperation.createDirectory:
        return isComplete ? '已创建目录: $details' : '创建目录: $details';
      case SyncOperation.deletePath:
        return isComplete ? '已删除: $details' : '删除: $details';
      case SyncOperation.renamePath:
        return isComplete ? '已重命名: $details' : '重命名: $details';
      case SyncOperation.detectChanges:
        return isComplete ? '变更检测完成' : '检测变更中...';
      case SyncOperation.verifyRemote:
        return isComplete ? '远程验证完成' : '验证远程路径...';
      default:
        return details;
    }
  }
}

class SyncStatusManager {
  final _statusSubject = BehaviorSubject<List<SyncStatusEvent>>.seeded([]);
  final List<SyncStatusEvent> _statusHistory = [];
  final int maxHistoryLength = 20; // 最多保留20条记录

  Stream<List<SyncStatusEvent>> get statusStream => _statusSubject.stream;

  void addEvent(SyncOperation operation, String details,
      {bool isComplete = false}) {
    final event = SyncStatusEvent(
      operation: operation,
      details: details,
      isComplete: isComplete,
    );

    _statusHistory.insert(0, event);
    if (_statusHistory.length > maxHistoryLength) {
      _statusHistory.removeLast();
    }

    _statusSubject.add(List.from(_statusHistory));
  }

  List<SyncStatusEvent> getCurrentStatus() {
    return List.from(_statusHistory);
  }

  void clear() {
    _statusHistory.clear();
    _statusSubject.add([]);
  }

  void dispose() {
    _statusSubject.close();
  }
}
