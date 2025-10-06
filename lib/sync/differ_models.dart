import 'snapshot.dart';

enum ChangeType { Create, Modify, Delete, Rename, MetadataChange }

class Change {
  final ChangeType type;
  final String path;
  final FileMetadata? metadata;
  final String? oldPath;

  Change({
    required this.type,
    required this.path,
    this.metadata,
    this.oldPath,
  });
}

class Conflict {
  final String path;
  final FileMetadata? alphaMetadata;
  final FileMetadata? betaMetadata;

  Conflict({
    required this.path,
    this.alphaMetadata,
    this.betaMetadata,
  });
}

class SyncPlan {
  final List<Change> alphaToBeta;
  final List<Change> betaToAlpha;
  final List<Conflict> conflicts;

  SyncPlan({
    required this.alphaToBeta,
    required this.betaToAlpha,
    required this.conflicts,
  });

  bool get hasChanges => alphaToBeta.isNotEmpty || betaToAlpha.isNotEmpty;
}

