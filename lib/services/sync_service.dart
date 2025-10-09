import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/sync_entry.dart';
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
import 'sync_status_manager.dart';

class SyncConfig {
  String? localPath;
  String? remoteUser;
  String? remoteHost;
  String? remotePath;
  int? remotePort;
  String? identityFile;

  SyncConfig(
      {this.localPath,
      this.remoteUser,
      this.remoteHost,
      this.remotePath,
      this.remotePort,
      this.identityFile});

  bool get isComplete =>
      (localPath != null && localPath!.isNotEmpty) &&
      (remoteUser != null && remoteUser!.isNotEmpty) &&
      (remoteHost != null && remoteHost!.isNotEmpty) &&
      (remotePath != null && remotePath!.isNotEmpty);
}

// 删除重复的导入行
// import 'sync_status_manager.dart';

class SyncService {
  // Keep a single session name for now; could be made configurable.
  static const String _sessionName = 'codebisync';

  final SyncConfig config = SyncConfig();
  final Map<String, DateTime> _lastSyncRecords = {};
  final SyncStatusManager _statusManager = SyncStatusManager();
  final SyncController _controller = SyncController();
  bool _sessionRunning = false;

  // 添加获取状态管理器的方法
  SyncStatusManager get statusManager => _statusManager;

  // 修改status方法以返回详细状态
  Future<String> getStatus() async {
    if (_sessionRunning && _controller.hasSession(_sessionName)) {
      final statusEvents = _statusManager.getCurrentStatus();
      if (statusEvents.isEmpty) {
        return 'Session running (Alpha→Beta). 源: ${config.localPath}\n目标: ${config.remotePath}';
      } else {
        final messages = statusEvents.map((e) => e.formattedMessage).join('\n');
        return '当前同步状态:\n$messages';
      }
    }
    return 'No active session';
  }

  // 在up方法中添加初始状态
  Future<void> up() async {
    // Switch to internal sync pipeline: require local and remote paths only
    if (config.localPath == null ||
        config.localPath!.isEmpty ||
        config.remotePath == null ||
        config.remotePath!.isEmpty) {
      throw StateError('配置不完整：需要本地目录和目标目录');
    }

    final alpha = LocalEndpoint(config.localPath!);
    final beta = RsyncEndpoint(
      host: config.remoteHost!,
      user: config.remoteUser!,
      remoteRoot: config.remotePath!,
      localRoot: config.localPath!,
      port: config.remotePort ?? 22,
      identityFile: config.identityFile,
      statusManager: _statusManager, // 传递状态管理器
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

    final statePath = p.join(config.localPath!, '.codebisync', 'baseline.json');
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

    await _controller.createSession(sessionId: _sessionName, session: session);
    _sessionRunning = true;
    _recordDirectorySync(config.localPath!);
  }

  Future<List<SyncEntry>> listRemoteEntries() async {
    final host = config.remoteHost;
    final user = config.remoteUser;
    final basePath = config.remotePath;
    if (host == null || user == null || basePath == null || basePath.isEmpty)
      return [];

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
      } catch (_) {}
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
}
