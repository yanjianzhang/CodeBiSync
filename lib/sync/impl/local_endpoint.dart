import 'dart:io';

import 'package:path/path.dart' as p;

import '../endpoint.dart';
import '../stager.dart';
import '../differ.dart';
import '../snapshot.dart';
import '../util.dart';
import '../differ_models.dart';
import '../../services/sync_status_manager.dart';
import '../../services/connection_daemon.dart';

class LocalEndpoint implements IncrementalEndpoint {
  final String root;
  final SyncStatusManager? statusManager; // 添加状态管理器
  late final String _rootCanonical;
  late final String _rootWithSep;

  LocalEndpoint(this.root, {this.statusManager}) {
    final abs = Directory(root).absolute.path;
    _rootCanonical = p.normalize(abs);
    _rootWithSep = _rootCanonical.endsWith(p.separator) ? _rootCanonical : '$_rootCanonical${p.separator}';
  }

  @override
  Future<void> apply(StagingData staging) async {
    // Apply metadata changes (create directories/files, deletes, renames etc.)
    for (final change in staging.metadataChanges) {
      final target = _abs(change.path);
      switch (change.type) {
        case ChangeType.create:
          if (change.metadata?.isDirectory == true) {
            await Directory(target).create(recursive: true);
          } else {
            final dir = Directory(target).parent;
            if (!await dir.exists()) await dir.create(recursive: true);
            await File(target).create(recursive: true);
          }
          break;
        case ChangeType.delete:
          final f = File(target);
          final d = Directory(target);
          if (await f.exists()) await f.delete();
          if (await d.exists()) await d.delete(recursive: true);
          break;
        case ChangeType.rename:
          final old = _abs(change.oldPath ?? change.path);
          if (await File(old).exists()) {
            await File(old).rename(target);
          } else if (await Directory(old).exists()) {
            await Directory(old).rename(target);
          }
          break;
        case ChangeType.modify:
        case ChangeType.metadataChange:
          // For MVP, no-op; file data applied via chunks below
          break;
      }
    }

    // Apply byte chunks
    for (final chunk in staging.dataChunks) {
      final target = _abs(chunk.path);
      final file = File(target);
      final raf = await file.open(mode: FileMode.writeOnlyAppend);
      try {
        // For simplicity, if offset is 0 and file exists, truncate
        if (chunk.offset == 0) {
          await raf.truncate(0);
        }
        await raf.setPosition(chunk.offset);
        await raf.writeFrom(chunk.data);
      } finally {
        await raf.close();
      }
    }
  }

  @override
  Future<Snapshot> scan() async {
    statusManager?.addEvent(SyncOperation.scanFiles, '扫描本地文件系统');

    try {
      final entries = <String, FileMetadata>{};
      final dir = Directory(root);
      if (!await dir.exists()) {
        throw Exception('Local directory does not exist: $root');
      }

      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        final relPath = p.relative(entity.path, from: root);
        // 精确过滤.codebisync目录及其所有子内容
        if (p.split(relPath).contains('.codebisync')) {
          continue;
        }
        
        final stat = await entity.stat();
        entries[relPath] = FileMetadata(
          path: relPath,
          isDirectory: entity is Directory,
          size: stat.size,
          mtime: stat.modified,
        );
      }

      statusManager?.addEvent(SyncOperation.scanFiles, '本地文件扫描完成', isComplete: true);
      return Snapshot(entries);
    } catch (e) {
      statusManager?.addEvent(SyncOperation.scanFiles, '本地文件扫描失败', isComplete: true);
      rethrow;
    }
  }

  @override
  Future<void> delete(String path) async {
    final full = _abs(path);
    if (await File(full).exists()) {
      await File(full).delete();
    } else if (await Directory(full).exists()) {
      await Directory(full).delete(recursive: true);
    }
  }

  @override
  Future<List<int>> readChunk(String path, int offset, int length) async {
    final file = File(_abs(path));
    if (!await file.exists()) return [];
    final raf = await file.open(mode: FileMode.read);
    try {
      await raf.setPosition(offset);
      return await raf.read(length);
    } finally {
      await raf.close();
    }
  }

  @override
  Future<void> rename(String oldPath, String newPath) async {
    final oldFull = _abs(oldPath);
    final newFull = _abs(newPath);
    if (await File(oldFull).exists()) {
      await File(oldFull).rename(newFull);
    } else if (await Directory(oldFull).exists()) {
      await Directory(oldFull).rename(newFull);
    }
  }

  @override
  Future<void> setMetadata(String path, FileMetadata metadata) async {
    // Minimal: set modification time only
    final full = _abs(path);
    try {
      await File(full).setLastModified(metadata.mtime);
    } catch (_) {
      // ignore
    }
  }

  @override
  Future<void> writeChunk(String path, int offset, List<int> chunk) async {
    final target = File(_abs(path));
    if (!await target.parent.exists()) await target.parent.create(recursive: true);
    final raf = await target.open(mode: FileMode.writeOnlyAppend);
    try {
      if (offset == 0) await raf.truncate(0);
      await raf.setPosition(offset);
      await raf.writeFrom(chunk);
    } finally {
      await raf.close();
    }
  }

  String _abs(String relative) =>
      p.isAbsolute(relative) ? p.normalize(relative) : p.normalize(p.join(_rootCanonical, relative));

  String? _relative(String absolute) {
    final normalized = p.normalize(absolute);
    if (normalized == _rootCanonical) return '';
    if (!normalized.startsWith(_rootWithSep)) return null;
    final rel = p.relative(normalized, from: _rootCanonical);
    if (rel.startsWith('..')) return null;
    return rel == '.' ? '' : rel;
  }

  @override
  Future<Snapshot> refreshSnapshot({
    required Snapshot previous,
    required Set<String> relativePaths,
  }) async {
    if (relativePaths.isEmpty) {
      return previous;
    }

    if (relativePaths.any((e) => e.isEmpty)) {
      return scan();
    }

    final normalized = _normalize(relativePaths);
    if (normalized.contains('')) {
      return scan();
    }

    final next = Map<String, FileMetadata>.from(previous.entries);

    for (final rel in normalized) {
      await _refreshPath(rel, next);
    }

    return Snapshot(next);
  }

  Set<String> _normalize(Set<String> inputs) {
    final out = <String>{};
    for (final raw in inputs) {
      final candidate = raw.trim();
      if (candidate.isEmpty) {
        out.clear();
        out.add('');
        return out;
      }

      String value = candidate;
      if (p.isAbsolute(value)) {
        final rel = _relative(value);
        if (rel == null || rel.isEmpty) {
          out.clear();
          out.add('');
          return out;
        }
        value = rel;
      } else {
        value = p.normalize(value);
      }

      if (value == '.' || value.startsWith('..')) {
        out.clear();
        out.add('');
        return out;
      }

      out.add(value);
    }
    return out;
  }

  Future<void> _refreshPath(String rel, Map<String, FileMetadata> map) async {
    final abs = _abs(rel);
    FileSystemEntityType type;
    try {
      type = await FileSystemEntity.type(abs, followLinks: false);
    } catch (_) {
      type = FileSystemEntityType.notFound;
    }

    switch (type) {
      case FileSystemEntityType.directory:
        await _refreshDirectory(rel, map);
        break;
      case FileSystemEntityType.file:
        await _refreshFile(rel, map);
        break;
      case FileSystemEntityType.notFound:
        _removeSubtree(map, rel);
        break;
      default:
        _removeSubtree(map, rel);
        break;
    }
  }

  Future<void> _refreshFile(String rel, Map<String, FileMetadata> map) async {
    final file = File(_abs(rel));
    try {
      final stat = await file.stat();
      map[rel] = FileMetadata(
        path: rel,
        isDirectory: false,
        size: stat.size,
        mtime: stat.modified,
        checksum: null,
      );
    } catch (_) {
      _removeSubtree(map, rel);
    }
  }

  Future<void> _refreshDirectory(String rel, Map<String, FileMetadata> map) async {
    final dir = Directory(_abs(rel));
    if (!await dir.exists()) {
      _removeSubtree(map, rel);
      return;
    }

    _removeSubtree(map, rel);
    try {
      final stat = await dir.stat();
      map[rel] = FileMetadata(
        path: rel,
        isDirectory: true,
        size: 0,
        mtime: stat.modified,
        checksum: null,
      );
    } catch (_) {
      return;
    }

    try {
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        final relPath = _relative(entity.path);
        if (relPath == null || relPath.isEmpty) continue;
        try {
          final stat = await entity.stat();
          if (entity is File) {
            map[relPath] = FileMetadata(
              path: relPath,
              isDirectory: false,
              size: stat.size,
              mtime: stat.modified,
              checksum: null,
            );
          } else if (entity is Directory) {
            map[relPath] = FileMetadata(
              path: relPath,
              isDirectory: true,
              size: 0,
              mtime: stat.modified,
              checksum: null,
            );
          }
        } catch (_) {
          map.remove(relPath);
        }
      }
    } catch (_) {
      // Swallow transient listing errors; next full scan will fix.
    }
  }

  void _removeSubtree(Map<String, FileMetadata> map, String rel) {
    if (rel.isEmpty) {
      map.clear();
      return;
    }
    final prefix = '$rel${p.separator}';
    final toRemove = <String>[];
    map.forEach((key, value) {
      if (key == rel || key.startsWith(prefix)) {
        toRemove.add(key);
      }
    });
    for (final key in toRemove) {
      map.remove(key);
    }
  }
}
