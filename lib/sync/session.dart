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
        // Alpha → Beta
        if (plan.alphaToBeta.isNotEmpty) {
          final a2b = SyncPlan(
            alphaToBeta: plan.alphaToBeta,
            betaToAlpha: const [],
            conflicts: const [],
          );
          final stagingA2B = stager.prepare(a2b);
          await transport.send(stagingA2B);
          await endpointBeta.apply(stagingA2B);
        }

        // Beta → Alpha（仅当 Beta 是 RsyncEndpoint 时，拉取文件到本地）
        if (plan.betaToAlpha.isNotEmpty) {
          for (final ch in plan.betaToAlpha) {
            switch (ch.type) {
              case ChangeType.Create:
              case ChangeType.Modify:
                if (endpointBeta is dynamic && (endpointBeta as dynamic).pull != null) {
                  try {
                    await (endpointBeta as dynamic).pull(ch.path);
                  } catch (_) {}
                }
                break;
              case ChangeType.Delete:
                await endpointAlpha.delete(ch.path);
                break;
              case ChangeType.Rename:
                if (ch.oldPath != null) {
                  await endpointAlpha.rename(ch.oldPath!, ch.path);
                }
                break;
              case ChangeType.MetadataChange:
                break;
            }
          }
        }

        // TODO: 可将 conflicts 上报给 UI 或记录日志

        // 保存新基线（此处简单地用本轮扫描作为新基线）
        await stateStore.saveNewBaseline(alphaSnap, betaSnap, StagingData(metadataChanges: [], dataChunks: []));
      }
    }
  }
}
