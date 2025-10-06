import 'dart:io';

import '../endpoint.dart';
import '../stager.dart';
import '../differ.dart';
import '../snapshot.dart';
import '../util.dart';

class LocalEndpoint implements Endpoint {
  final String root;

  LocalEndpoint(this.root);

  @override
  Future<void> apply(StagingData staging) async {
    // Apply metadata changes (create directories/files, deletes, renames etc.)
    for (final change in staging.metadataChanges) {
      final target = _abs(change.path);
      switch (change.type) {
        case ChangeType.Create:
          if (change.metadata?.isDirectory == true) {
            await Directory(target).create(recursive: true);
          } else {
            final dir = Directory(target).parent;
            if (!await dir.exists()) await dir.create(recursive: true);
            await File(target).create(recursive: true);
          }
          break;
        case ChangeType.Delete:
          final f = File(target);
          final d = Directory(target);
          if (await f.exists()) await f.delete();
          if (await d.exists()) await d.delete(recursive: true);
          break;
        case ChangeType.Rename:
          final old = _abs(change.oldPath ?? change.path);
          if (await File(old).exists()) {
            await File(old).rename(target);
          } else if (await Directory(old).exists()) {
            await Directory(old).rename(target);
          }
          break;
        case ChangeType.Modify:
        case ChangeType.MetadataChange:
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
    return scanDirectory(root);
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
      relative.startsWith(root) ? relative : '${root.endsWith('/') ? root.substring(0, root.length - 1) : root}/$relative';
}
