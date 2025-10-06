import 'endpoint.dart';
import 'watcher.dart';
import 'snapshot.dart';
import 'differ.dart';
import 'stager.dart';
import 'transport.dart';
import 'state_store.dart';

class Session {
  final Endpoint endpointAlpha;
  final Endpoint endpointBeta;
  final Watcher watcher;
  final Differ differ;
  final Stager stager;
  final Transport transport;
  final StateStore stateStore;

  bool _canceled = false;

  Session({
    required this.endpointAlpha,
    required this.endpointBeta,
    required this.watcher,
    required this.differ,
    required this.stager,
    required this.transport,
    required this.stateStore,
  });

  void cancel() {
    _canceled = true;
  }

  Future<void> runLoop() async {
    while (!_canceled) {
      // 等待变更或超时
      await watcher.waitForChangeOrTimeout();

      // 扫描两端
      Snapshot alphaSnap = await endpointAlpha.scan();
      Snapshot betaSnap = await endpointBeta.scan();

      // 载入基线
      Snapshot? baseAlpha = stateStore.loadBaselineAlpha();
      Snapshot? baseBeta = stateStore.loadBaselineBeta();
      // 如果没有基线，则视作初次同步，base = empty snapshot
      Snapshot base = baseAlpha ?? Snapshot({});

      // 差异 & 合并
      SyncPlan plan = differ.reconcile(base, alphaSnap, betaSnap);

      if (plan.hasChanges) {
        // 准备 staging 数据
        StagingData staging = stager.prepare(plan);

        // 单向传输示例：从 Alpha → Beta（可以根据模式调整方向）
        await transport.send(staging);
        await endpointBeta.apply(staging);

        // 如果你支持双向或 beta → alpha，也在这里做
        // ...

        // 保存新基线
        await stateStore.saveNewBaseline(alphaSnap, betaSnap, staging);
      }
    }
  }
}
