import '../differ.dart';
import '../snapshot.dart';

/// A very simple differ: one-way Alpha -> Beta, using mtime/size to decide.
class SimpleDiffer implements Differ {
  @override
  SyncPlan reconcile(Snapshot base, Snapshot alpha, Snapshot beta) {
    final alphaToBeta = <Change>[];
    final betaToAlpha = <Change>[]; // unused in one-way demo
    final conflicts = <Conflict>[];

    for (final entry in alpha.entries.values) {
      final b = beta.entries[entry.path];
      if (b == null) {
        alphaToBeta.add(Change(type: ChangeType.Create, path: entry.path, metadata: entry));
      } else {
        if (!entry.isDirectory) {
          if (entry.size != b.size || entry.mtime.isAfter(b.mtime)) {
            alphaToBeta.add(Change(type: ChangeType.Modify, path: entry.path, metadata: entry));
          }
        }
      }
    }

    // Deletions: if path exists in beta but not in alpha, delete from beta
    for (final bEntry in beta.entries.values) {
      if (!alpha.entries.containsKey(bEntry.path)) {
        alphaToBeta.add(Change(type: ChangeType.Delete, path: bEntry.path));
      }
    }

    return SyncPlan(alphaToBeta: alphaToBeta, betaToAlpha: betaToAlpha, conflicts: conflicts);
  }
}

