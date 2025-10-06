import 'staging_models.dart';
import 'differ.dart';
export 'staging_models.dart' show ByteChunk, StagingData;

abstract class Stager {
  StagingData prepare(SyncPlan plan);
}
