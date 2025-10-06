import 'dart:io';
import 'package:path/path.dart' as p;
import 'snapshot.dart';

/// 在本地文件系统上扫描目录，生成 Snapshot（工具函数示例）
Future<Snapshot> scanDirectory(String rootPath) async {
  final Map<String, FileMetadata> map = {};

  // Normalize base to avoid trailing slash issues and resolve simple segments
  final base = rootPath.replaceAll(RegExp(r'/+$'), '');
  final baseWithSep = base + Platform.pathSeparator;
  final rootDir = Directory(base);
  if (!await rootDir.exists()) {
    return Snapshot(map);
  }

  try {
    await for (FileSystemEntity entity in rootDir.list(recursive: true, followLinks: false)) {
      final full = entity.path;
      String rel;
      if (full.startsWith(baseWithSep)) {
        rel = full.substring(baseWithSep.length);
      } else {
        rel = p.relative(full, from: base);
      }
      final stat = await entity.stat();
      if (entity is File) {
        map[rel] = FileMetadata(
          path: rel,
          isDirectory: false,
          size: stat.size,
          mtime: stat.modified,
          checksum: null,
        );
      } else if (entity is Directory) {
        map[rel] = FileMetadata(
          path: rel,
          isDirectory: true,
          size: 0,
          mtime: stat.modified,
          checksum: null,
        );
      }
    }
  } catch (_) {
    // If listing fails due to permissions or transient errors, return what we've collected.
  }

  return Snapshot(map);
}
