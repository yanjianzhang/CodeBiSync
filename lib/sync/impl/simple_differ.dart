import '../differ.dart';
import '../snapshot.dart';

/// A simple differ: two-way using mtime/size; conflicts when both sides changed.
class SimpleDiffer implements Differ {
  @override
  SyncPlan reconcile(Snapshot base, Snapshot alpha, Snapshot beta) {
    final alphaToBeta = <Change>[];
    final betaToAlpha = <Change>[];
    final conflicts = <Conflict>[];

    final paths = <String>{}
      ..addAll(base.entries.keys)
      ..addAll(alpha.entries.keys)
      ..addAll(beta.entries.keys);

    for (final path in paths) {
      final a = alpha.entries[path];
      final b = beta.entries[path];
      final bas = base.entries[path];

      // Create cases
      if (bas == null && a != null && b == null) {
        alphaToBeta.add(Change(type: ChangeType.create, path: path, metadata: a));
        continue;
      }
      if (bas == null && b != null && a == null) {
        betaToAlpha.add(Change(type: ChangeType.create, path: path, metadata: b));
        continue;
      }

      // Delete cases
      if (bas != null && a == null && b != null) {
        // deleted at alpha only -> delete beta
        betaToAlpha.add(Change(type: ChangeType.delete, path: path));
        continue;
      }
      if (bas != null && b == null && a != null) {
        // deleted at beta only -> delete beta target or push from alpha?
        alphaToBeta.add(Change(type: ChangeType.delete, path: path));
        continue;
      }

      if (a == null && b == null) {
        continue; // both deleted
      }

      // Modify cases
      if (a != null && b != null) {
        final aChanged = bas == null || a.mtime.isAfter(bas.mtime) || a.size != bas.size;
        final bChanged = bas == null || b.mtime.isAfter(bas.mtime) || b.size != bas.size;

        if (aChanged && !bChanged) {
          alphaToBeta.add(Change(type: ChangeType.modify, path: path, metadata: a));
        } else if (!aChanged && bChanged) {
          betaToAlpha.add(Change(type: ChangeType.modify, path: path, metadata: b));
        } else if (aChanged && bChanged) {
          // both changed -> conflict (mtime newer side could win later)
          conflicts.add(Conflict(path: path, alphaMetadata: a, betaMetadata: b));
          // default policy: newer mtime wins; emit direction
          if (a.mtime.isAfter(b.mtime)) {
            alphaToBeta.add(Change(type: ChangeType.modify, path: path, metadata: a));
          } else if (b.mtime.isAfter(a.mtime)) {
            betaToAlpha.add(Change(type: ChangeType.modify, path: path, metadata: b));
          }
        }
      }
    }

    return SyncPlan(alphaToBeta: alphaToBeta, betaToAlpha: betaToAlpha, conflicts: conflicts);
  }
}
