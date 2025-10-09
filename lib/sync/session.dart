import 'dart:async';

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
  Snapshot? _alphaSnapshot;
  Snapshot? _betaSnapshot;

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
    watcher.drainChanges(); // 清理启动时的噪音事件
    var firstIteration = true;

    while (!_canceled) {
      WatchEventBatch batch;
      RemoteChangeBatch remoteChanges;
      if (firstIteration) {
        batch = WatchEventBatch.fullRescan();
        remoteChanges = RemoteChangeBatch.fullRescan();
        firstIteration = false;
      } else {
        await watcher.waitForChangeOrTimeout();
        batch = watcher.drainChanges();
        remoteChanges = await _collectRemoteChanges(
          force: batch.requiresFullRescan || _betaSnapshot == null,
        );
        if (!batch.requiresFullRescan &&
            batch.paths.isEmpty &&
            !remoteChanges.requiresFullRescan &&
            remoteChanges.paths.isEmpty) {
          continue;
        }
      }

      final alphaSnap = await _scanAlpha(batch);
      if (alphaSnap == null) {
        await Future.delayed(const Duration(milliseconds: 250));
        continue;
      }
      _alphaSnapshot = alphaSnap;

      final betaSnap = await _refreshBetaSnapshot(remoteChanges);
      if (betaSnap == null) {
        await Future.delayed(const Duration(milliseconds: 250));
        continue;
      }
      _betaSnapshot = betaSnap;

      // 载入基线
      Snapshot? baseAlpha = stateStore.loadBaselineAlpha();
      Snapshot? baseBeta = stateStore.loadBaselineBeta();
      // 如果没有基线，则视作初次同步，base = empty snapshot
      Snapshot base = baseAlpha ?? Snapshot({});

      // 差异 & 合并
      SyncPlan plan = differ.reconcile(base, alphaSnap, betaSnap);

      final baselineMissing = baseAlpha == null || baseBeta == null;

      if (plan.hasChanges) {
        final betaVerification = <String>{};
        final alphaAdjustments = <String>{};

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

          for (final ch in plan.alphaToBeta) {
            betaVerification.add(ch.path);
            if (ch.type == ChangeType.rename && ch.oldPath != null) {
              betaVerification.add(ch.oldPath!);
            }
          }
        }

        // Beta → Alpha（仅当 Beta 是 RsyncEndpoint 时，拉取文件到本地）
        if (plan.betaToAlpha.isNotEmpty) {
          for (final ch in plan.betaToAlpha) {
            switch (ch.type) {
              case ChangeType.create:
              case ChangeType.modify:
                if (endpointBeta is PullableEndpoint) {
                  try {
                    await (endpointBeta as PullableEndpoint).pull(ch.path);
                  } catch (_) {}
                }
                alphaAdjustments.add(ch.path);
                break;
              case ChangeType.delete:
                await endpointAlpha.delete(ch.path);
                alphaAdjustments.add(ch.path);
                break;
              case ChangeType.rename:
                if (ch.oldPath != null) {
                  await endpointAlpha.rename(ch.oldPath!, ch.path);
                  alphaAdjustments.add(ch.path);
                  alphaAdjustments.add(ch.oldPath!);
                }
                break;
              case ChangeType.metadataChange:
                break;
            }
          }
        }

        // TODO: 可将 conflicts 上报给 UI 或记录日志

        if (betaVerification.isNotEmpty) {
          await _verifyRemotePaths(betaVerification);
        }

        if (alphaAdjustments.isNotEmpty) {
          await _refreshAlphaSnapshot(alphaAdjustments);
        }
      }

      if ((plan.hasChanges || baselineMissing) && _alphaSnapshot != null && _betaSnapshot != null) {
        await stateStore.saveNewBaseline(
          _alphaSnapshot!,
          _betaSnapshot!,
          StagingData(metadataChanges: [], dataChunks: []),
        );
      }
    }
  }

  Future<Snapshot?> _scanAlpha(WatchEventBatch batch) async {
    try {
      if (_alphaSnapshot == null || batch.requiresFullRescan) {
        return await endpointAlpha.scan();
      }

      if (batch.paths.isEmpty) {
        return _alphaSnapshot;
      }

      if (endpointAlpha is IncrementalEndpoint) {
        final inc = endpointAlpha as IncrementalEndpoint;
        return await inc.refreshSnapshot(
          previous: _alphaSnapshot!,
          relativePaths: batch.paths,
        );
      }

      return await endpointAlpha.scan();
    } catch (_) {
      return null;
    }
  }

  Future<RemoteChangeBatch> _collectRemoteChanges({required bool force}) async {
    if (endpointBeta is RemoteIncrementalEndpoint) {
      try {
        return await (endpointBeta as RemoteIncrementalEndpoint).detectRemoteChanges(
          previous: _betaSnapshot,
          forceFull: force,
        );
      } catch (_) {
        return RemoteChangeBatch.fullRescan();
      }
    }
    return force ? RemoteChangeBatch.fullRescan() : RemoteChangeBatch.empty();
  }

  Future<Snapshot?> _refreshBetaSnapshot(RemoteChangeBatch changes) async {
    try {
      if (_betaSnapshot == null || changes.requiresFullRescan) {
        final snap = await endpointBeta.scan();
        _betaSnapshot = snap;
        return snap;
      }

      if (changes.paths.isEmpty) {
        return _betaSnapshot;
      }

      if (endpointBeta is IncrementalEndpoint) {
        final inc = endpointBeta as IncrementalEndpoint;
        final snap = await inc.refreshSnapshot(
          previous: _betaSnapshot!,
          relativePaths: changes.paths,
        );
        _betaSnapshot = snap;
        return snap;
      }

      final snap = await endpointBeta.scan();
      _betaSnapshot = snap;
      return snap;
    } catch (_) {
      return null;
    }
  }

  Future<void> _verifyRemotePaths(Set<String> paths) async {
    if (_betaSnapshot == null) {
      _betaSnapshot = await endpointBeta.scan();
      return;
    }
    if (endpointBeta is IncrementalEndpoint) {
      try {
        _betaSnapshot = await (endpointBeta as IncrementalEndpoint).refreshSnapshot(
          previous: _betaSnapshot!,
          relativePaths: paths,
        );
      } catch (_) {
        _betaSnapshot = await endpointBeta.scan();
      }
    } else {
      _betaSnapshot = await endpointBeta.scan();
    }
  }

  Future<void> _refreshAlphaSnapshot(Set<String> paths) async {
    if (_alphaSnapshot == null || paths.isEmpty) return;
    if (endpointAlpha is IncrementalEndpoint) {
      try {
        _alphaSnapshot = await (endpointAlpha as IncrementalEndpoint).refreshSnapshot(
          previous: _alphaSnapshot!,
          relativePaths: paths,
        );
        return;
      } catch (_) {}
    }
    _alphaSnapshot = await endpointAlpha.scan();
  }
}
