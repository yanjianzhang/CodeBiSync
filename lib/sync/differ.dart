import 'snapshot.dart';
import 'differ_models.dart';
export 'differ_models.dart' show ChangeType, Change, Conflict, SyncPlan;

abstract class Differ {
  SyncPlan reconcile(Snapshot base, Snapshot alpha, Snapshot beta);
}
