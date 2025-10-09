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

class SyncConfig {
  String? localPath;
  String? remoteUser;
  String? remoteHost;
  String? remotePath;
  int? remotePort;
  String? identityFile;

  SyncConfig({this.localPath, this.remoteUser, this.remoteHost, this.remotePath, this.remotePort, this.identityFile});

  bool get isComplete =>
      (localPath != null && localPath!.isNotEmpty) &&
      (remoteUser != null && remoteUser!.isNotEmpty) &&
      (remoteHost != null && remoteHost!.isNotEmpty) &&
      (remotePath != null && remotePath!.isNotEmpty);
}

class SyncService {
  // Keep a single session name for now; could be made configurable.
  static const String _sessionName = 'codebisync';

  final SyncConfig config = SyncConfig();
  final Map<String, DateTime> _lastSyncRecords = {};

  void updateConfig({String? localPath, String? remoteUser, String? remoteHost, String? remotePath, int? remotePort, String? identityFile}) {
    if (localPath != null) config.localPath = localPath;
    if (remoteUser != null) config.remoteUser = remoteUser;
    if (remoteHost != null) config.remoteHost = remoteHost;
    if (remotePath != null) config.remotePath = remotePath;
    if (remotePort != null) config.remotePort = remotePort;
    if (identityFile != null) config.identityFile = identityFile;
  }

  /// Parse an ssh command string to extract `[user]` and `host`.
  /// Examples supported: `ssh host`, `ssh user@host`, with arbitrary options like `-p 2222 -C`.
  /// Returns a map with keys: 'user' and 'host' when detected.
  Map<String, String> parseSshCommand(String input) {
    // Tokenize by whitespace, preserving non-option tokens.
    final tokens = input.trim().split(RegExp(r"\s+")).where((t) => t.isNotEmpty).toList();
    if (tokens.isEmpty || tokens.first != 'ssh') return {};

    // Scan tokens for a plausible host spec: the first non-option token after options
    // Options may be forms like: -p 22, -i key, -o Option=value
    String? hostToken;
    for (int i = 1; i < tokens.length; i++) {
      final t = tokens[i];
      if (t.startsWith('-')) {
        // Skip the following token if the option expects an argument and it's not in -oX=Y form
        if (t == '-p' || t == '-i' || t == '-l' || t == '-b' || t == '-F' || t == '-J' || t == '-S') {
          i++; // skip next as arg if present
        }
        continue;
      }
      hostToken = t;
      break;
    }

    if (hostToken == null || hostToken.isEmpty) return {};

    // Strip any trailing command (in rare forms like: ssh host command) — we only take the first host token
    // Parse user@host if present, else just host.
    String? user;
    String host;
    if (hostToken.contains('@')) {
      final parts = hostToken.split('@');
      if (parts.length >= 2) {
        user = parts[0];
        host = parts.sublist(1).join('@'); // In case @ appears in some unusual alias
      } else {
        host = hostToken;
      }
    } else {
      host = hostToken;
    }

    final out = <String, String>{};
    if (user != null && user.isNotEmpty) out['user'] = user;
    if (host.isNotEmpty) out['host'] = host;
    return out;
  }

  final SyncController _controller = SyncController();
  bool _sessionRunning = false;

  Future<void> up() async {
    // Switch to internal sync pipeline: require local and remote paths only
    if (config.localPath == null || config.localPath!.isEmpty || config.remotePath == null || config.remotePath!.isEmpty) {
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
    );
    final watcher = FsWatcher(
      root: config.localPath!,
      maxInterval: const Duration(seconds: 3),
      debounce: const Duration(milliseconds: 200),
    );
    final differ = SimpleDiffer();
    final stager = SimpleStager(config.localPath!);
    final transport = LocalTransport();
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
    );

    await _controller.createSession(sessionId: _sessionName, session: session);
    _sessionRunning = true;
    _recordDirectorySync(config.localPath!);
  }

  Future<String> status() async {
    if (_sessionRunning && _controller.hasSession(_sessionName)) {
      return 'Session running (Alpha→Beta). 源: ${config.localPath}\n目标: ${config.remotePath}';
    }
    return 'No active session';
  }

  Future<List<SyncEntry>> listRemoteEntries() async {
    final host = config.remoteHost;
    final user = config.remoteUser;
    final basePath = config.remotePath;
    if (host == null || user == null || basePath == null || basePath.isEmpty) return [];

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
        if ((keyPath == null || keyPath.isEmpty) && m.identityFiles.isNotEmpty) {
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
          final rel = current == basePath ? e.name : p.join(p.relative(current, from: basePath), e.name);
          results.add(SyncEntry(name: rel, isDirectory: e.isDirectory, status: SyncStatus.pending));
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
        final baseline = p.join(config.localPath!, '.codebisync', 'baseline.json');
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
      return p.basename(a.path).toLowerCase().compareTo(p.basename(b.path).toLowerCase());
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

  void _recordDirectorySync(String path) {
    final dir = Directory(path);
    if (!dir.existsSync()) return;

    for (final entity in dir.listSync(followLinks: false)) {
      _lastSyncRecords[entity.path] = DateTime.now();
    }
  }
}
