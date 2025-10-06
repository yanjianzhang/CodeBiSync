import 'snapshot.dart';
import 'stager.dart';

abstract class StateStore {
  /// 载入上一次基线快照
  Snapshot? loadBaselineAlpha();
  Snapshot? loadBaselineBeta();

  /// 保存当前基线快照（同步成功后调用）
  Future<void> saveNewBaseline(
      Snapshot alpha, Snapshot beta, StagingData staging);
}
