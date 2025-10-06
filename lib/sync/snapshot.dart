class FileMetadata {
  final String path; // 相对路径
  final bool isDirectory;
  final int size;
  final DateTime mtime;
  final String? checksum; // 可选：哈希 /校验和

  FileMetadata({
    required this.path,
    required this.isDirectory,
    required this.size,
    required this.mtime,
    this.checksum,
  });
}

class Snapshot {
  final Map<String, FileMetadata> entries;

  Snapshot(this.entries);

  FileMetadata? getMetadata(String relativePath) {
    return entries[relativePath];
  }
}
