enum SyncStatus {
  synced,
  pending,
  failed,
}

class SyncEntry {
  final String name;
  final bool isDirectory;
  final DateTime? modifiedAt;
  final DateTime? lastSyncAt;
  final SyncStatus status;

  const SyncEntry({
    required this.name,
    required this.isDirectory,
    this.modifiedAt,
    this.lastSyncAt,
    this.status = SyncStatus.pending,
  });

  SyncEntry copyWith({
    String? name,
    bool? isDirectory,
    DateTime? modifiedAt,
    DateTime? lastSyncAt,
    SyncStatus? status,
  }) {
    return SyncEntry(
      name: name ?? this.name,
      isDirectory: isDirectory ?? this.isDirectory,
      modifiedAt: modifiedAt ?? this.modifiedAt,
      lastSyncAt: lastSyncAt ?? this.lastSyncAt,
      status: status ?? this.status,
    );
  }
}
