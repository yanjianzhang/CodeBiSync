import 'dart:io';
import 'package:path/path.dart' as p;
import '../endpoint.dart';
import '../snapshot.dart';
import '../stager.dart';
import '../differ_models.dart';
import '../../services/sync_status_manager.dart';

class MockRemoteEndpoint implements RemoteIncrementalEndpoint {
  final SyncStatusManager? statusManager;

  // 模拟远程文件系统
  final Map<String, FileMetadata> _files = {};
  final Map<String, List<int>> _fileContents = {};

  MockRemoteEndpoint({this.statusManager});

  @override
  Future<void> apply(StagingData staging) async {
    // 模拟应用元数据变更
    for (final change in staging.metadataChanges) {
      switch (change.type) {
        case ChangeType.create:
          if (change.metadata?.isDirectory == true) {
            _files[change.path] = change.metadata!;
          } else {
            _files[change.path] = change.metadata!;
            _fileContents[change.path] = [];
          }
          break;
        case ChangeType.delete:
          _files.remove(change.path);
          _fileContents.remove(change.path);
          break;
        case ChangeType.modify:
          // 修改文件元数据
          final oldMetadata = _files[change.path];
          if (oldMetadata != null) {
            _files[change.path] = oldMetadata.copyWith(
              path: change.path,
              size: change.metadata?.size ?? oldMetadata.size,
              mtime: change.metadata?.mtime ?? oldMetadata.mtime,
              checksum: change.metadata?.checksum ?? oldMetadata.checksum,
            );
          }
          break;
        case ChangeType.rename:
          final oldEntry = _files.remove(change.oldPath!);
          final oldContent = _fileContents.remove(change.oldPath!);
          if (oldEntry != null) {
            _files[change.path] = oldEntry.copyWith(path: change.path);
          }
          if (oldContent != null) {
            _fileContents[change.path] = oldContent;
          }
          break;
      }
    }

    // 模拟应用数据块
    for (final chunk in staging.dataChunks) {
      _fileContents[chunk.path] = chunk.data;
    }
  }

  @override
  Future<Snapshot> scan() async {
    return Snapshot(Map.from(_files));
  }

  @override
  Future<List<int>> readData(String relativePath) async {
    return _fileContents[relativePath] ?? [];
  }

  @override
  Future<bool> verifyRemotePathExists(String relativePath) async {
    return _files.containsKey(relativePath);
  }
  
  // 实现Endpoint接口的所有方法
  @override
  Future<List<int>> readChunk(String path, int offset, int length) async {
    final content = _fileContents[path] ?? [];
    final end = (offset + length < content.length) ? offset + length : content.length;
    return content.sublist(offset, end);
  }

  @override
  Future<void> writeChunk(String path, int offset, List<int> chunk) async {
    final content = _fileContents[path] ?? [];
    final newContent = content.toList();
    
    // 确保列表足够长以容纳新数据
    while (newContent.length < offset + chunk.length) {
      newContent.add(0);
    }
    
    // 写入数据
    for (int i = 0; i < chunk.length; i++) {
      newContent[offset + i] = chunk[i];
    }
    
    _fileContents[path] = newContent;
  }

  @override
  Future<void> delete(String path) async {
    _files.remove(path);
    _fileContents.remove(path);
  }

  @override
  Future<void> rename(String oldPath, String newPath) async {
    final metadata = _files.remove(oldPath);
    final content = _fileContents.remove(oldPath);
    if (metadata != null) {
      _files[newPath] = metadata.copyWith(path: newPath);
    }
    if (content != null) {
      _fileContents[newPath] = content;
    }
  }

  @override
  Future<void> setMetadata(String path, FileMetadata metadata) async {
    _files[path] = metadata;
  }
  
  // 实现IncrementalEndpoint接口的方法
  @override
  Future<Snapshot> refreshSnapshot({
    required Snapshot previous,
    required Set<String> relativePaths,
  }) async {
    // 简化实现，直接返回当前快照
    return Snapshot(Map.from(_files));
  }
  
  // 实现RemoteIncrementalEndpoint接口的方法
  @override
  Future<RemoteChangeBatch> detectRemoteChanges({
    Snapshot? previous,
    bool forceFull = false,
  }) async {
    return RemoteChangeBatch.empty();
  }

  // 工具方法：添加文件（用于测试）
  void addFile(String relativePath, String content) {
    final now = DateTime.now();
    _files[relativePath] = FileMetadata(
      path: relativePath,
      isDirectory: false,
      size: content.length,
      mtime: now,
    );
    _fileContents[relativePath] = content.codeUnits;
  }

  // 工具方法：添加目录（用于测试）
  void addDirectory(String relativePath) {
    final now = DateTime.now();
    _files[relativePath] = FileMetadata(
      path: relativePath,
      isDirectory: true,
      size: 0,
      mtime: now,
    );
  }

  // 工具方法：更新文件（用于测试）
  void updateFile(String relativePath, String content) {
    final now = DateTime.now();
    final metadata = _files[relativePath];
    if (metadata != null) {
      _files[relativePath] = metadata.copyWith(
        size: content.length,
        mtime: now,
      );
      _fileContents[relativePath] = content.codeUnits;
    }
  }

  // 工具方法：重命名文件（用于测试）
  void renameFile(String oldPath, String newPath) {
    final metadata = _files.remove(oldPath);
    final content = _fileContents.remove(oldPath);
    if (metadata != null) {
      _files[newPath] = metadata.copyWith(path: newPath);
    }
    if (content != null) {
      _fileContents[newPath] = content;
    }
  }
}