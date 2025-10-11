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
  final String? filePath; // 添加文件路径信息

  SyncStatusEvent({
    required this.operation,
    required this.details,
    this.isComplete = false,
    this.filePath,
  }) : timestamp = DateTime.now();

  String get formattedMessage {
    final filePart = filePath != null ? ' [$filePath]' : '';
    switch (operation) {
      case SyncOperation.scanFiles:
        return isComplete ? '扫描文件完成$filePart' : '扫描文件中...$filePart';
      case SyncOperation.uploadFile:
        return isComplete ? '已上传: $details$filePart' : '正在上传: $details$filePart';
      case SyncOperation.downloadFile:
        return isComplete ? '已下载: $details$filePart' : '正在下载: $details$filePart';
      case SyncOperation.verifyFile:
        return isComplete ? '验证完成: $details$filePart' : '验证文件: $details$filePart';
      case SyncOperation.createDirectory:
        return isComplete ? '已创建目录: $details$filePart' : '创建目录: $details$filePart';
      case SyncOperation.deletePath:
        return isComplete ? '已删除: $details$filePart' : '删除: $details$filePart';
      case SyncOperation.renamePath:
        return isComplete ? '已重命名: $details$filePart' : '重命名: $details$filePart';
      case SyncOperation.detectChanges:
        return isComplete ? '变更检测完成$filePart' : '检测变更中...$filePart';
      case SyncOperation.verifyRemote:
        return isComplete ? '远程验证完成$filePart' : '验证远程路径...$filePart';
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
      {bool isComplete = false, String? filePath}) {
    final event = SyncStatusEvent(
      operation: operation,
      details: details,
      isComplete: isComplete,
      filePath: filePath,
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

