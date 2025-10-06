import 'dart:convert';
import 'dart:io';

import '../snapshot.dart';
import '../stager.dart';
import '../state_store.dart';

class FileStateStore implements StateStore {
  final String path;

  FileStateStore(this.path);

  Map<String, dynamic>? _load() {
    final f = File(path);
    if (!f.existsSync()) return null;
    try {
      return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  @override
  Snapshot? loadBaselineAlpha() {
    final m = _load();
    if (m == null) return null;
    return Snapshot(_mapFromJson(m['alpha'] as Map<String, dynamic>?));
  }

  @override
  Snapshot? loadBaselineBeta() {
    final m = _load();
    if (m == null) return null;
    return Snapshot(_mapFromJson(m['beta'] as Map<String, dynamic>?));
  }

  @override
  Future<void> saveNewBaseline(Snapshot alpha, Snapshot beta, StagingData staging) async {
    final f = File(path);
    final m = <String, dynamic>{
      'alpha': _mapToJson(alpha.entries),
      'beta': _mapToJson(beta.entries),
    };
    await f.parent.create(recursive: true);
    await f.writeAsString(jsonEncode(m));
  }

  Map<String, dynamic> _mapToJson(Map<String, FileMetadata> map) =>
      map.map((k, v) => MapEntry(k, {
            'path': v.path,
            'isDirectory': v.isDirectory,
            'size': v.size,
            'mtime': v.mtime.toIso8601String(),
            'checksum': v.checksum,
          }));

  Map<String, FileMetadata> _mapFromJson(Map<String, dynamic>? m) {
    if (m == null) return {};
    final out = <String, FileMetadata>{};
    m.forEach((k, v) {
      final j = v as Map<String, dynamic>;
      out[k] = FileMetadata(
        path: j['path'] as String,
        isDirectory: j['isDirectory'] as bool,
        size: (j['size'] as num).toInt(),
        mtime: DateTime.parse(j['mtime'] as String),
        checksum: j['checksum'] as String?,
      );
    });
    return out;
  }
}

