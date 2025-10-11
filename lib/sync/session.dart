import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'endpoint.dart';
import 'watcher.dart';
import 'snapshot.dart';
import 'differ.dart';
import 'stager.dart';
import 'transport.dart';
import 'state_store.dart';
import '../sync/impl/rsync_endpoint.dart'; // 添加RsyncEndpoint导入
import '../sync/impl/local_endpoint.dart'; // 添加LocalEndpoint导入
import '../services/sync_status_manager.dart'; // 添加状态管理器导入

class Session {
  final Endpoint endpointAlpha;
  final Endpoint endpointBeta;
  final Watcher watcher;
  final Differ differ;
  final Stager stager;
  final Transport transport;
  final StateStore stateStore;
  final SyncStatusManager statusManager; // 添加状态管理器

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
    required this.statusManager, // 添加到构造函数
  });

  void cancel() {
    _canceled = true;
  }

  Future<void> runLoop() async {
    watcher.drainChanges(); // 清理启动时的噪音事件
    var firstIteration = true;

    while (!_canceled) {
      statusManager.addEvent(SyncOperation.detectChanges, '等待文件变更');

WatchEventBatch batch;
      RemoteChangeBatch remoteChanges;
      if (firstIteration) {
        batch = WatchEventBatch.fullRescan();
        remoteChanges = RemoteChangeBatch.fullRescan();
        firstIteration = false;
        statusManager.addEvent(SyncOperation.scanFiles, '首次扫描文件系统');
      } else {
        await watcher.waitForChangeOrTimeout();
        batch = watcher.drainChanges();
        statusManager.addEvent(SyncOperation.detectChanges, '检测本地变更');

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
      statusManager.addEvent(SyncOperation.detectChanges, '分析文件差异');
      SyncPlan plan = differ.reconcile(base, alphaSnap, betaSnap);
      statusManager.addEvent(SyncOperation.detectChanges, '分析文件差异',
          isComplete: true);

      final baselineMissing = baseAlpha == null || baseBeta == null;

      if (plan.hasChanges) {
        statusManager.addEvent(SyncOperation.scanFiles, '准备同步变更');
        final betaVerification = <String>{};
        final alphaAdjustments = <String>{};

        // Alpha → Beta
        if (plan.alphaToBeta.isNotEmpty) {
          statusManager.addEvent(SyncOperation.uploadFile, '开始上传文件到远程');

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

            // 记录每个文件的上传状态
            switch (ch.type) {
              case ChangeType.create:
              case ChangeType.modify:
                statusManager.addEvent(SyncOperation.uploadFile, ch.path,
                    isComplete: true);
                break;
              case ChangeType.delete:
                statusManager.addEvent(SyncOperation.deletePath, ch.path,
                    isComplete: true);
                break;
              case ChangeType.rename:
                if (ch.oldPath != null) {
                  statusManager.addEvent(
                      SyncOperation.renamePath, '${ch.oldPath} → ${ch.path}',
                      isComplete: true);
                }
                break;
              default:
                break;
            }
          }

          statusManager.addEvent(SyncOperation.uploadFile, '文件上传完成',
              isComplete: true);
        }

        // Beta → Alpha（仅当 Beta 是 RsyncEndpoint 时，拉取文件到本地）
        if (plan.betaToAlpha.isNotEmpty) {
          statusManager.addEvent(SyncOperation.downloadFile, '开始从远程下载文件');

          for (final ch in plan.betaToAlpha) {
            switch (ch.type) {
              case ChangeType.create:
              case ChangeType.modify:
                if (endpointBeta is PullableEndpoint) {
                  try {
                    statusManager.addEvent(SyncOperation.downloadFile, ch.path);
                    await (endpointBeta as PullableEndpoint).pull(ch.path);
                    statusManager.addEvent(SyncOperation.downloadFile, ch.path,
                        isComplete: true);
                  } catch (_) {
                    // 可以在这里添加错误处理
                  }
                }
                alphaAdjustments.add(ch.path);
                break;
              case ChangeType.delete:
                statusManager.addEvent(SyncOperation.deletePath, ch.path);
                await endpointAlpha.delete(ch.path);
                statusManager.addEvent(SyncOperation.deletePath, ch.path,
                    isComplete: true);
                alphaAdjustments.add(ch.path);
                break;
              case ChangeType.rename:
                if (ch.oldPath != null) {
                  statusManager.addEvent(
                      SyncOperation.renamePath, '${ch.oldPath} → ${ch.path}');
                  await endpointAlpha.rename(ch.oldPath!, ch.path);
                  statusManager.addEvent(
                      SyncOperation.renamePath, '${ch.oldPath} → ${ch.path}',
                      isComplete: true);
                  alphaAdjustments.add(ch.path);
                  alphaAdjustments.add(ch.oldPath!);
                }
                break;
              case ChangeType.metadataChange:
                break;
            }
          }

          statusManager.addEvent(SyncOperation.downloadFile, '文件下载完成',
              isComplete: true);
        }

        // TODO: 可将 conflicts 上报给 UI 或记录日志

        if (betaVerification.isNotEmpty) {
          await _verifyRemotePaths(betaVerification);
        }

        if (alphaAdjustments.isNotEmpty) {
          await _refreshAlphaSnapshot(alphaAdjustments);
        }
      }

      if ((plan.hasChanges || baselineMissing) &&
          _alphaSnapshot != null &&
          _betaSnapshot != null) {
        statusManager.addEvent(SyncOperation.scanFiles, '保存同步基线');
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
        statusManager.addEvent(SyncOperation.scanFiles, '扫描本地文件系统');
        final result = await endpointAlpha.scan();
        statusManager.addEvent(SyncOperation.scanFiles, '本地文件扫描完成',
            isComplete: true);
        return result;
      }

      if (batch.paths.isEmpty) {
        return _alphaSnapshot;
      }

      if (endpointAlpha is IncrementalEndpoint) {
        final inc = endpointAlpha as IncrementalEndpoint;
        statusManager.addEvent(SyncOperation.scanFiles, '增量扫描本地变更');
        final result = await inc.refreshSnapshot(
          previous: _alphaSnapshot!,
          relativePaths: batch.paths,
        );
        statusManager.addEvent(SyncOperation.scanFiles, '本地变更扫描完成',
            isComplete: true);
        return result;
      }

      statusManager.addEvent(SyncOperation.scanFiles, '重新扫描本地文件系统');
      final result = await endpointAlpha.scan();
      statusManager.addEvent(SyncOperation.scanFiles, '本地文件扫描完成',
          isComplete: true);
      return result;
    } catch (_) {
      statusManager.addEvent(SyncOperation.scanFiles, '本地文件扫描失败',
          isComplete: true);
      return null;
    }
  }

  Future<RemoteChangeBatch> _collectRemoteChanges({required bool force}) async {
    if (endpointBeta is RemoteIncrementalEndpoint) {
      try {
        statusManager.addEvent(SyncOperation.detectChanges, '检测远程文件变更');
        final result = await (endpointBeta as RemoteIncrementalEndpoint)
            .detectRemoteChanges(
          previous: _betaSnapshot,
          forceFull: force,
        );
        statusManager.addEvent(SyncOperation.detectChanges, '远程变更检测完成',
            isComplete: true);
        return result;
      } catch (_) {
        statusManager.addEvent(SyncOperation.detectChanges, '远程变更检测失败',
            isComplete: true);
        return RemoteChangeBatch.fullRescan();
      }
    }
    return force ? RemoteChangeBatch.fullRescan() : RemoteChangeBatch.empty();
  }

  Future<Snapshot?> _refreshBetaSnapshot(RemoteChangeBatch changes) async {
    try {
      if (_betaSnapshot == null || changes.requiresFullRescan) {
        statusManager.addEvent(SyncOperation.scanFiles, '扫描远程文件系统');
        final snap = await endpointBeta.scan();
        _betaSnapshot = snap;
        statusManager.addEvent(SyncOperation.scanFiles, '远程文件扫描完成',
            isComplete: true);
        return snap;
      }

      if (changes.paths.isEmpty) {
        return _betaSnapshot;
      }

      if (endpointBeta is IncrementalEndpoint) {
        final inc = endpointBeta as IncrementalEndpoint;
        statusManager.addEvent(SyncOperation.scanFiles, '增量扫描远程变更');
        final snap = await inc.refreshSnapshot(
          previous: _betaSnapshot!,
          relativePaths: changes.paths,
        );
        _betaSnapshot = snap;
        statusManager.addEvent(SyncOperation.scanFiles, '远程变更扫描完成',
            isComplete: true);
        return snap;
      }

      statusManager.addEvent(SyncOperation.scanFiles, '重新扫描远程文件系统');
      final snap = await endpointBeta.scan();
      _betaSnapshot = snap;
      statusManager.addEvent(SyncOperation.scanFiles, '远程文件扫描完成',
          isComplete: true);
      return snap;
    } catch (_) {
      statusManager.addEvent(SyncOperation.scanFiles, '远程文件扫描失败',
          isComplete: true);
      return null;
    }
  }

  Future<void> _verifyRemotePaths(Set<String> paths) async {
    if (_betaSnapshot == null) {
      statusManager.addEvent(SyncOperation.scanFiles, '准备验证远程路径');
      _betaSnapshot = await endpointBeta.scan();
      return;
    }

    // 对于RsyncEndpoint，进行更严格的验证
    if (endpointBeta is RsyncEndpoint) {
      final rsyncEndpoint = endpointBeta as RsyncEndpoint;
      statusManager.addEvent(SyncOperation.verifyRemote, '验证远程文件完整性');

      for (final path in paths) {
        // 跳过baseline.json文件的验证，因为它由系统自动管理
        if (path.contains('.codebisync/baseline.json')) {
          continue;
        }
        
        // 检查文件是否在排除规则中
        bool isExcluded = false;
        for (final exclude in rsyncEndpoint.excludes) {
          // 简单的匹配检查（实际项目中可能需要更复杂的模式匹配）
          if (path.contains(exclude) || 
              (exclude.startsWith('*') && path.endsWith(exclude.substring(1))) ||
              (exclude.endsWith('/') && path.startsWith(exclude))) {
            isExcluded = true;
            break;
          }
        }
        
        // 如果文件在排除列表中，则跳过验证
        if (isExcluded) {
          statusManager.addEvent(SyncOperation.verifyFile, '跳过验证(已排除): $path',
              isComplete: true, filePath: path);
          continue;
        }

        try {
          // 验证文件是否存在
          statusManager.addEvent(SyncOperation.verifyFile, path, filePath: path);
          final exists = await rsyncEndpoint.verifyRemotePathExists(path,
              isDirectory: null);

          if (!exists) {
            statusManager.addEvent(SyncOperation.verifyFile, '验证失败: $path',
                isComplete: true, filePath: path);
            throw Exception('Remote path not found after sync: $path');
          }

          statusManager.addEvent(SyncOperation.verifyFile, path,
              isComplete: true, filePath: path);

          // 可以在这里添加额外的内容验证逻辑
          // 例如，使用rsync --checksum进行校验和比较
        } catch (e) {
          print('Verification failed for $path: $e');
          // 如果验证失败，重新同步文件
          if (endpointAlpha is LocalEndpoint) {
            final localEndpoint = endpointAlpha as LocalEndpoint;
            final localFilePath = p.join(localEndpoint.root, path);
            if (File(localFilePath).existsSync()) {
              try {
                statusManager.addEvent(SyncOperation.uploadFile, '重新上传: $path', filePath: path);
                await rsyncEndpoint.rsyncFile(path);
                statusManager.addEvent(
                    SyncOperation.uploadFile, '重新上传成功: $path',
                    isComplete: true, filePath: path);
              } catch (retryError) {
                statusManager.addEvent(
                    SyncOperation.uploadFile, '重新上传失败: $path',
                    isComplete: true, filePath: path);
                print('Retry sync failed for $path: $retryError');
              }
            }
          }
        }
      }

      statusManager.addEvent(SyncOperation.verifyRemote, '远程文件验证完成',
          isComplete: true);
    }

    // 刷新远程快照
    if (endpointBeta is IncrementalEndpoint) {
      try {
        statusManager.addEvent(SyncOperation.scanFiles, '刷新远程快照');
        _betaSnapshot =
            await (endpointBeta as IncrementalEndpoint).refreshSnapshot(
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
    statusManager.addEvent(SyncOperation.scanFiles, '刷新本地快照');
    if (endpointAlpha is IncrementalEndpoint) {
      try {
        _alphaSnapshot =
            await (endpointAlpha as IncrementalEndpoint).refreshSnapshot(
          previous: _alphaSnapshot!,
          relativePaths: paths,
        );
        statusManager.addEvent(SyncOperation.scanFiles, '本地快照刷新完成',
            isComplete: true);
        return;
      } catch (_) {}
    }
    _alphaSnapshot = await endpointAlpha.scan();
    statusManager.addEvent(SyncOperation.scanFiles, '本地快照刷新完成',
        isComplete: true);
  }

  Future<SyncPlan> detectChanges() async {
    statusManager.addEvent(SyncOperation.detectChanges, '检测文件变更');
    
    try {
      final baseAlpha = stateStore.loadBaselineAlpha();
      final baseBeta = stateStore.loadBaselineBeta();

      _alphaSnapshot = await endpointAlpha.scan();
      _betaSnapshot = await endpointBeta.scan();

      // 过滤掉.codebisync目录
      if (baseAlpha != null) {
        baseAlpha.entries.removeWhere((key, _) => key.contains('.codebisync'));
      }
      
      if (baseBeta != null) {
        baseBeta.entries.removeWhere((key, _) => key.contains('.codebisync'));
      }
      
      _alphaSnapshot?.entries.removeWhere((key, _) => key.contains('.codebisync'));
      _betaSnapshot?.entries.removeWhere((key, _) => key.contains('.codebisync'));

      final plan = differ.reconcile(
        baseAlpha ?? Snapshot({}),
        _alphaSnapshot ?? Snapshot({}),
        _betaSnapshot ?? Snapshot({}),
      );
      
      statusManager.addEvent(SyncOperation.detectChanges, '变更检测完成', isComplete: true);
      return plan;
    } catch (e) {
      statusManager.addEvent(SyncOperation.detectChanges, '变更检测失败: $e', isComplete: true);
      rethrow;
    }
  }

  Future<void> syncAll() async {
    statusManager.addEvent(SyncOperation.detectChanges, '开始检测变更');
    
    try {
      final changes = await detectChanges();
      if (changes.alphaToBeta.isEmpty && changes.betaToAlpha.isEmpty) {
        statusManager.addEvent(SyncOperation.detectChanges, '未检测到变更', isComplete: true);
        return;
      }

      final alphaToBeta = changes.alphaToBeta
          .where((c) => !c.path.contains('.codebisync')) // 过滤掉.codebisync目录
          .toList();
      final betaToAlpha = changes.betaToAlpha
          .where((c) => !c.path.contains('.codebisync')) // 过滤掉.codebisync目录
          .toList();

      final staging = await _stage(alphaToBeta, betaToAlpha);
      if (staging.metadataChanges.isEmpty && staging.dataChunks.isEmpty) {
        statusManager.addEvent(SyncOperation.detectChanges, '没有需要同步的文件', isComplete: true);
        return;
      }

      await _transportAll(staging);
      await stateStore.saveNewBaseline(
          _alphaSnapshot!, _betaSnapshot!, staging);
      
      statusManager.addEvent(SyncOperation.detectChanges, '同步完成', isComplete: true);
    } catch (e, s) {
      statusManager.addEvent(SyncOperation.detectChanges, '同步失败: $e', isComplete: true);
      Error.throwWithStackTrace(e, s);
    }
  }

  Future<StagingData> _stage(List<Change> alphaToBeta, List<Change> betaToAlpha) async {
    statusManager.addEvent(SyncOperation.detectChanges, '准备同步数据');
    
    try {
      // 过滤掉.codebisync目录
      final filteredAlphaToBeta = alphaToBeta
          .where((c) => !c.path.contains('.codebisync'))
          .toList();
      final filteredBetaToAlpha = betaToAlpha
          .where((c) => !c.path.contains('.codebisync'))
          .toList();

      final plan = SyncPlan(
        alphaToBeta: filteredAlphaToBeta,
        betaToAlpha: filteredBetaToAlpha,
        conflicts: [],
      );
      
      final staging = stager.prepare(plan);
      
      statusManager.addEvent(SyncOperation.detectChanges, '同步数据准备完成', isComplete: true);
      return staging;
    } catch (e) {
      statusManager.addEvent(SyncOperation.detectChanges, '同步数据准备失败: $e', isComplete: true);
      rethrow;
    }
  }

  Future<void> _transportAll(StagingData staging) async {
    statusManager.addEvent(SyncOperation.detectChanges, '传输同步数据');
    
    try {
      await transport.send(staging);
      statusManager.addEvent(SyncOperation.detectChanges, '数据传输完成', isComplete: true);
    } catch (e) {
      statusManager.addEvent(SyncOperation.detectChanges, '数据传输失败: $e', isComplete: true);
      rethrow;
    }
  }
}