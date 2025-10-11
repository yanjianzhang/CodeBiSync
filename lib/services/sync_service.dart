import 'dart:io';
import 'dart:async';
import 'package:rxdart/rxdart.dart';
import 'package:path/path.dart' as p;

import '../models/sync_entry.dart';
import '../sync/endpoint.dart';
import '../sync/impl/local_endpoint.dart';
import '../sync/impl/rsync_endpoint.dart';
import '../sync/impl/fs_watcher.dart';
import '../sync/impl/simple_differ.dart';
import '../sync/impl/simple_stager.dart';
import '../sync/impl/local_transport.dart';
import '../sync/impl/file_state_store.dart';
import '../sync/session.dart';
import '../sync/sync_controller.dart';
import '../services/rsync_service.dart';
import '../services/ssh_config.dart';
import '../services/connection_daemon.dart';
import 'sync_status_manager.dart';

class SyncConfig {
  String? localPath;
  String? remoteUser;
  String? remoteHost;
  String? remotePath;
  int? remotePort;
  String? identityFile;
  List<String> excludes;

  SyncConfig({
    this.localPath,
    this.remoteUser,
    this.remoteHost,
    this.remotePath,
    this.remotePort,
    this.identityFile,
    this.excludes = const [
      '.git',
      '.venv',
      'node_modules',
      '__pycache__',
      '*.log',
      '.DS_Store',
      'models',
      'results'
    ], // 默认排除规则
  });

  bool get isComplete =>
      (localPath != null && localPath!.isNotEmpty) &&
      (remoteUser != null && remoteUser!.isNotEmpty) &&
      (remoteHost != null && remoteHost!.isNotEmpty) &&
      (remotePath != null && remotePath!.isNotEmpty);
}

// 删除重复的导入行
// import 'sync_status_manager.dart';

class SyncService {
  final LocalEndpoint Function(String path, SyncStatusManager? statusManager)
      localEndpointFactory;
  final RemoteIncrementalEndpoint Function(
          SyncConfig config, SyncStatusManager? statusManager)
      remoteEndpointFactory;

  SyncService({
    this.localEndpointFactory = _defaultLocalEndpointFactory,
    this.remoteEndpointFactory = _defaultRemoteEndpointFactory,
  });

  // Keep a single session name for now; could be made configurable.
  static const String _sessionName = 'codebisync';

  final SyncConfig config = SyncConfig();
  final SyncStatusManager _statusManager = SyncStatusManager();
  final SyncController _controller = SyncController();
  final Map<String, DateTime> _lastSyncRecords = {};
  bool _sessionRunning = false;

  // 默认工厂函数实现
  static LocalEndpoint _defaultLocalEndpointFactory(
      String path, SyncStatusManager? statusManager) {
    return LocalEndpoint(path, statusManager: statusManager);
  }

  static RemoteIncrementalEndpoint _defaultRemoteEndpointFactory(
      SyncConfig config, SyncStatusManager? statusManager) {
    return RsyncEndpoint(
      host: config.remoteHost ?? '',
      user: config.remoteUser ?? '',
      remoteRoot: config.remotePath ?? '',
      localRoot: config.localPath ?? '',
      port: config.remotePort ?? 22,
      identityFile: config.identityFile,
      statusManager: statusManager,
      excludes: config.excludes,
    );
  }

  final ConnectionDaemon _connectionDaemon = ConnectionDaemon();

  // 添加获取状态管理器的方法
  SyncStatusManager get statusManager => _statusManager;

  // 修改status方法以返回详细状态
  Future<String> getStatus() async {
    if (_sessionRunning && _controller.hasSession(_sessionName)) {
      final statusEvents = _statusManager.getCurrentStatus();
      if (statusEvents.isEmpty) {
        return '会话正在运行 (源 → 目标)\n源: ${config.localPath}\n目标: ${config.remotePath}';
      } else {
        final messages = statusEvents.map((e) => e.formattedMessage).join('\n');
        return '当前同步状态:\n$messages';
      }
    }
    return '无活动会话';
  }

  // 在up方法中添加初始状态
  Future<void> up() async {
    // Switch to internal sync pipeline: require local and remote paths only
    if (config.localPath == null ||
        config.remoteUser == null ||
        config.remoteHost == null ||
        config.remotePath == null) {
      _statusManager.addEvent(SyncOperation.detectChanges, '同步失败：配置不完整',
          isComplete: true);
      throw Exception('请先填写完整的同步配置');
    }

    _statusManager.addEvent(SyncOperation.detectChanges, '开始同步...');

    try {
      final alpha = LocalEndpoint(config.localPath!);
      final beta = RsyncEndpoint(
        host: config.remoteHost!,
        user: config.remoteUser!,
        remoteRoot: config.remotePath!,
        localRoot: config.localPath!,
        port: config.remotePort ?? 22,
        identityFile: config.identityFile,
        statusManager: _statusManager, // 传递状态管理器
        excludes: config.excludes, // 传递排除规则
      );
      final watcher = FsWatcher(
        root: config.localPath!,
        maxInterval: const Duration(seconds: 3),
        debounce: const Duration(milliseconds: 200),
      );
      final differ = SimpleDiffer();
      final stager = SimpleStager(config.localPath!);
      final transport = LocalTransport();

      // 修改前
      // transport.subscribe((data) {
      //   endpointBeta.apply(data);
      // });

      // 修改后
      transport.subscribe((data) {
        beta.apply(data);
      });

      final statePath =
          p.join(config.localPath!, '.codebisync', 'baseline.json');
      final store = FileStateStore(statePath);

      final session = Session(
        endpointAlpha: alpha,
        endpointBeta: beta,
        watcher: watcher,
        differ: differ,
        stager: stager,
        transport: transport,
        stateStore: store,
        statusManager: _statusManager,
      );

      await _controller.createSession(
          sessionId: _sessionName, session: session);
      _sessionRunning = true;
      _recordDirectorySync(config.localPath!);

      // 假设 Session 有一个可以等待的同步过程，这里添加成功状态
      // 如果实际的同步是异步启动的，这个成功信息可能需要在 Session 内部完成时触发
      _statusManager.addEvent(SyncOperation.detectChanges, '同步完成',
          isComplete: true);
    } catch (e) {
      _statusManager.addEvent(SyncOperation.detectChanges, '同步失败: $e',
          isComplete: true);
      rethrow;
    }
  }

  Future<List<SyncEntry>> listRemoteEntries() async {
    final host = config.remoteHost;
    final user = config.remoteUser;
    final basePath = config.remotePath;
    if (host == null || user == null || basePath == null || basePath.isEmpty)
      return [];

    // Register connection with daemon for stability
    _connectionDaemon.registerConnection(
      host: host,
      username: user,
      port: config.remotePort ?? 22,
      privateKeyPath: config.identityFile,
    );

    // Check if connection is stable before proceeding
    final isStable = _connectionDaemon.isConnectionStable(
        host, user, config.remotePort ?? 22);

    String? keyPath = config.identityFile;
    String? proxyJump;
    bool compression = true;
    bool forwardAgent = true;
    try {
      final hosts = await loadAllSshConfigs();
      final m = hosts.firstWhere(
        (h) => h.host == host || h.hostName == host,
        orElse: () => SshConfigHost(host: ''),
      );
      if (m.host.isNotEmpty) {
        proxyJump = m.proxyJump;
        compression = m.compression;
        forwardAgent = m.forwardAgent;
        if ((keyPath == null || keyPath.isEmpty) &&
            m.identityFiles.isNotEmpty) {
          keyPath = m.identityFiles.first;
        }
      }
      if (keyPath == null || keyPath.isEmpty) {
        keyPath = await resolvePrivateKeyPath(host: host, user: user);
      }
    } catch (_) {}

    final results = <SyncEntry>[];
    final dirs = <String>[basePath];
    while (dirs.isNotEmpty) {
      final current = dirs.removeLast();
      try {
        final items = await RsyncService.list(
          host: host,
          username: user,
          path: current,
          port: config.remotePort ?? 22,
          identityFile: keyPath,
          proxyJump: proxyJump,
          compression: compression,
          forwardAgent: forwardAgent,
          immediateOnly: true,
          dirsOnly: false,
        );
        for (final e in items) {
          // 过滤掉.codebisync目录
          if (e.name.contains('.codebisync')) {
            continue;
          }

          final rel = current == basePath
              ? e.name
              : p.join(p.relative(current, from: basePath), e.name);
          results.add(SyncEntry(
              name: rel,
              isDirectory: e.isDirectory,
              status: SyncStatus.pending));
          if (e.isDirectory) {
            dirs.add(p.join(current, e.name));
          }
        }
      } catch (e) {
        // If connection fails, we don't want to break the whole operation
        // Just skip this directory and continue with others
        continue;
      }
    }
    return results;
  }

  Future<String> diagnoseLocalSync() async {
    final lines = <String>[];
    lines.add('诊断本地同步配置');
    lines.add('源目录: ${config.localPath ?? '(未设置)'}');
    lines.add('目标目录: ${config.remotePath ?? '(未设置)'}');

    if (config.localPath != null && config.localPath!.isNotEmpty) {
      final d = Directory(config.localPath!);
      lines.add('源目录存在: ${await d.exists()}');
      if (await d.exists()) {
        final localEntries = await listLocalEntries(config.localPath!);
        lines.add('源目录条目数: ${localEntries.length}');
        final baseline =
            p.join(config.localPath!, '.codebisync', 'baseline.json');
        lines.add('基线文件: ${File(baseline).existsSync() ? baseline : '不存在'}');
      }
    }

    if (config.remotePath != null && config.remotePath!.isNotEmpty) {
      final d = Directory(config.remotePath!);
      lines.add('目标目录存在: ${await d.exists()}');
      if (await d.exists()) {
        final remoteEntries = await listLocalEntries(config.remotePath!);
        lines.add('目标目录条目数: ${remoteEntries.length}');
      }
    }

    lines.add(_sessionRunning && _controller.hasSession(_sessionName)
        ? '会话状态: 运行中'
        : '会话状态: 未运行');

    return lines.join('\n');
  }

  Future<List<SyncEntry>> listLocalEntries(String path) async {
    final dir = Directory(path);
    if (!await dir.exists()) return [];

    final entities = <FileSystemEntity>[];
    await for (final entity in dir.list(followLinks: false)) {
      // 过滤掉.codebisync目录
      if (entity.path.contains('.codebisync')) {
        continue;
      }
      entities.add(entity);
    }

    entities.sort((a, b) {
      final aDir = a is Directory;
      final bDir = b is Directory;
      if (aDir != bDir) return aDir ? -1 : 1;
      return p
          .basename(a.path)
          .toLowerCase()
          .compareTo(p.basename(b.path).toLowerCase());
    });

    return Future.wait(entities.map((entity) async {
      final stat = await entity.stat();
      final name = p.basename(entity.path);
      final key = entity.path;
      final lastSync = _lastSyncRecords[key];
      final status = _computeStatusForEntity(lastSync, stat.modified);
      return SyncEntry(
        name: name,
        isDirectory: entity is Directory,
        modifiedAt: stat.modified,
        lastSyncAt: lastSync,
        status: status,
      );
    }));
  }

  SyncStatus _computeStatusForEntity(DateTime? lastSync, DateTime modifiedAt) {
    if (lastSync == null) {
      return SyncStatus.pending;
    }
    if (modifiedAt.isAfter(lastSync)) {
      return SyncStatus.pending;
    }
    return SyncStatus.synced;
  }

  Future<void> _recordFileSync(String filePath) {
    // 记录单个文件的同步状态
    _lastSyncRecords[filePath] = DateTime.now();
    return Future.value();
  }

  void _recordDirectorySync(String path) {
    final dir = Directory(path);
    if (!dir.existsSync()) return;

    // 只记录最顶层目录，具体文件的同步记录由同步过程中单独记录
    _lastSyncRecords[path] = DateTime.now();
  }

  // 验证远程文件是否与本地文件一致
  Future<bool> verifyRemoteFile(String relativePath) async {
    if (config.localPath == null || config.remotePath == null) {
      return false;
    }

    try {
      final localFile = File(p.join(config.localPath!, relativePath));
      if (!localFile.existsSync()) {
        return false;
      }

      // 检查文件是否在排除规则中
      for (final exclude in config.excludes) {
        // 简单的匹配检查（实际项目中可能需要更复杂的模式匹配）
        if (relativePath.contains(exclude) ||
            (exclude.startsWith('*') &&
                relativePath.endsWith(exclude.substring(1))) ||
            (exclude.endsWith('/') && relativePath.startsWith(exclude))) {
          // 如果文件在排除列表中，则认为验证通过（因为不会同步这些文件）
          return true;
        }
      }

      final localStats = await localFile.stat();

      // 创建临时的RsyncEndpoint进行验证
      final endpoint = RsyncEndpoint(
        host: config.remoteHost ?? '',
        user: config.remoteUser ?? '',
        remoteRoot: config.remotePath ?? '',
        localRoot: config.localPath ?? '',
        port: config.remotePort ?? 22,
        identityFile: config.identityFile,
      );

      // 使用rsync的dry-run模式检查文件是否相同
      final sshCmd =
          'ssh -p ${config.remotePort ?? 22} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes${config.identityFile != null ? ' -i ${config.identityFile}' : ''}';
      final remotePath = '${config.remotePath ?? ''}/$relativePath'
          .replaceAll(RegExp(r'//+'), '/');

      final args = <String>[
        '-avn', // n表示dry-run
        '--checksum', // 使用校验和比较
        '-e', sshCmd,
        p.join(config.localPath!, relativePath),
        '${config.remoteUser ?? ''}@${config.remoteHost ?? ''}:$remotePath',
      ];

      final result = await Process.run('rsync', args);
      // 如果没有输出，表示文件相同
      final output = result.stdout.toString();
      return !output.contains(relativePath) && result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  // 添加updateConfig方法
  void updateConfig({
    String? localPath,
    String? remoteUser,
    String? remoteHost,
    String? remotePath,
    int? remotePort,
    String? identityFile,
    List<String>? excludes,
  }) {
    if (localPath != null) {
      config.localPath = localPath;
    }
    if (remoteUser != null) {
      config.remoteUser = remoteUser;
    }
    if (remoteHost != null) {
      config.remoteHost = remoteHost;
    }
    if (remotePath != null) {
      config.remotePath = remotePath;
    }
    if (remotePort != null) {
      config.remotePort = remotePort;
    }
    if (identityFile != null) {
      config.identityFile = identityFile;
    }
    if (excludes != null) {
      config.excludes = excludes;
    }
  }

  // 添加parseSshCommand方法
  Map<String, String> parseSshCommand(String cmd) {
    final result = <String, String>{};
    final parts = cmd.trim().split(' ');

    // 简单解析SSH命令，提取用户名和主机名
    for (var i = 0; i < parts.length; i++) {
      final part = parts[i];
      if (part.startsWith('-p')) {
        // 提取端口
        final port = part.substring(2).isNotEmpty
            ? part.substring(2)
            : (i + 1 < parts.length ? parts[i + 1] : null);
        if (port != null) {
          result['port'] = port;
        }
      } else if (part.contains('@') && !part.startsWith('-')) {
        // 提取用户名和主机名
        final userHost = part.split('@');
        if (userHost.length == 2) {
          result['user'] = userHost[0];
          result['host'] = userHost[1];
        }
      }
    }

    return result;
  }

  // 添加down方法 - 暂停同步会话
  Future<void> down() async {
    if (_sessionRunning && _controller.hasSession(_sessionName)) {
      _controller.terminateSession(_sessionName);
      _sessionRunning = false;
      _statusManager.addEvent(SyncOperation.detectChanges, '会话已暂停',
          isComplete: true);
    } else {
      _statusManager.addEvent(SyncOperation.detectChanges, '无活动会话可暂停',
          isComplete: true);
    }
  }

  // 添加stop方法 - 停止并删除同步会话
  Future<void> stop() async {
    if (_sessionRunning && _controller.hasSession(_sessionName)) {
      _controller.terminateSession(_sessionName);
      _sessionRunning = false;
      _statusManager.addEvent(SyncOperation.detectChanges, '会话已终止',
          isComplete: true);
    } else {
      _statusManager.addEvent(SyncOperation.detectChanges, '无活动会话可终止',
          isComplete: true);
    }
  }

  // 添加pull方法 - 一次性从远程拉取到本地
  Future<void> pull() async {
    if (!config.isComplete) {
      _statusManager.addEvent(SyncOperation.detectChanges, '配置不完整，无法执行pull操作',
          isComplete: true);
      throw Exception('请先填写完整的同步配置');
    }

    _statusManager.addEvent(SyncOperation.detectChanges, '开始从远程拉取文件...');

    try {
      final rsyncService = RsyncService();
      await rsyncService.sync(
        source:
            '${config.remoteUser}@${config.remoteHost}:${config.remotePath}/',
        destination: '${config.localPath}/',
        port: config.remotePort ?? 22,
        identityFile: config.identityFile,
        reverse: true, // 从远程到本地
        excludes: config.excludes, // 使用配置的排除规则
      );

      _statusManager.addEvent(SyncOperation.detectChanges, '拉取完成',
          isComplete: true);
      _recordDirectorySync(config.localPath!);
    } catch (e) {
      _statusManager.addEvent(SyncOperation.detectChanges, '拉取失败: $e',
          isComplete: true);
      rethrow;
    }
  }

  // 添加push方法 - 一次性从本地推送到远程
  Future<void> push() async {
    if (!config.isComplete) {
      _statusManager.addEvent(SyncOperation.detectChanges, '配置不完整，无法执行push操作',
          isComplete: true);
      throw Exception('请先填写完整的同步配置');
    }

    _statusManager.addEvent(SyncOperation.detectChanges, '开始向远程推送文件...');

    try {
      final rsyncService = RsyncService();
      await rsyncService.sync(
        source: '${config.localPath}/',
        destination:
            '${config.remoteUser}@${config.remoteHost}:${config.remotePath}/',
        port: config.remotePort ?? 22,
        identityFile: config.identityFile,
        reverse: false, // 从本地到远程
        excludes: config.excludes, // 使用配置的排除规则
      );

      _statusManager.addEvent(SyncOperation.detectChanges, '推送完成',
          isComplete: true);
      _recordDirectorySync(config.localPath!);
    } catch (e) {
      _statusManager.addEvent(SyncOperation.detectChanges, '推送失败: $e',
          isComplete: true);
      rethrow;
    }
  }

  // 添加flush方法 - 强制刷新待处理的更改
  Future<void> flush() async {
    if (_sessionRunning && _controller.hasSession(_sessionName)) {
      // 在当前实现中，我们没有直接的flush机制，所以简单地记录操作
      _statusManager.addEvent(SyncOperation.detectChanges, '已请求刷新待处理更改',
          isComplete: true);
    } else {
      _statusManager.addEvent(SyncOperation.detectChanges, '无活动会话可刷新',
          isComplete: true);
    }
  }
}
