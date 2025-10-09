import 'snapshot.dart';
import 'stager.dart';

abstract class Endpoint {
  /// 扫描目录，返回快照
  Future<Snapshot> scan();

  /// 在该端点上应用变更（包括写入、删除、重命名、修改 metadata 等）
  Future<void> apply(StagingData staging);

  /// 读取部分文件块（如果做分块传输）
  Future<List<int>> readChunk(String path, int offset, int length);

  /// 写入部分文件块
  Future<void> writeChunk(String path, int offset, List<int> chunk);

  /// 删除路径
  Future<void> delete(String path);

  /// 重命名路径
  Future<void> rename(String oldPath, String newPath);

  /// 修改文件元数据（如修改时间、权限等）
  Future<void> setMetadata(String path, FileMetadata metadata);
}

abstract class IncrementalEndpoint implements Endpoint {
  /// 基于已有快照，针对给定相对路径集合做增量刷新。
  Future<Snapshot> refreshSnapshot({
    required Snapshot previous,
    required Set<String> relativePaths,
  });
}
