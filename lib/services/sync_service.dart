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
  static const String _homebrewShellenvCmd =
      "echo 'eval \"\$(/opt/homebrew/bin/brew shellenv)\"' >> ~/.zprofile && exec zsh";

  final SyncConfig config = SyncConfig();
  final Map<String, DateTime> _lastSyncRecords = {};
  String? _mutagenPathOverride;
  final List<String> _extraPaths = [];

  Map<String, String> _augmentedEnv() {
    final env = Map<String, String>.from(Platform.environment);
    final current = env['PATH'] ?? '';
    final candidates = ['/opt/homebrew/bin', '/usr/local/bin', ..._extraPaths];
    final parts = current.split(':');
    final toPrepend = candidates.where((p) => !parts.contains(p)).join(':');
    env['PATH'] = [toPrepend, current].where((s) => s.isNotEmpty).join(':');
    return env;
  }

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
    final watcher = FsWatcher(interval: const Duration(seconds: 2));
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

  Future<String> checkEnvironment() async {
    await _ensureMutagenResolved();
    final lines = <String>[];
    final envPath = _augmentedEnv()['PATH'] ?? '';

    final whichMutagen = await _runShell('command -v mutagen || true');
    final mutagenPath = (whichMutagen.stdout as String).trim();
    final brewMutagen = ['/opt/homebrew/bin/mutagen', '/usr/local/bin/mutagen']
        .firstWhere((p) => File(p).existsSync(), orElse: () => '');

    final resolvedPath = _mutagenPathOverride ??
        (mutagenPath.isNotEmpty
            ? mutagenPath
            : (brewMutagen.isNotEmpty ? brewMutagen : null));

    if (resolvedPath == null) {
      lines.add('✗ 未找到 mutagen（建议：brew install mutagen-io/mutagen/mutagen）');
      lines.add('PATH: ' + envPath);
    } else {
      lines.add('✓ mutagen: ' + resolvedPath);
      if (resolvedPath == brewMutagen && mutagenPath.isEmpty) {
        lines.add('  已临时使用 Homebrew 安装路径；如需永久生效请在 ~/.zprofile 中加入 Homebrew shellenv');
        _appendShellExample(lines, _homebrewShellenvCmd);
      }

      final quarantine = await _checkQuarantine(resolvedPath);
      if (quarantine != null) {
        lines.add('! 检测到隔离标记：' + quarantine);
        _appendShellExample(
          lines,
          'xattr -d com.apple.quarantine ' + resolvedPath,
          label: '  手动执行：',
        );
      }

      final versionRes = await _mutagen(['version']);
      if (versionRes.exitCode == 0) {
        final body = versionRes.stdout.toString().trim();
        if (body.isNotEmpty) lines.add(body);
      } else {
        lines.add(_prettyError('mutagen version', versionRes));
      }

      final probe = await _mutagen(['sync', 'list']);
      if (probe.exitCode != 0) {
        lines.add('! mutagen sync list 无法执行：');
        lines.add(_prettyError('mutagen sync list', probe));
      } else {
        lines.add('✓ mutagen sync list OK');
      }

      final dir = File(resolvedPath).parent.path;
      lines.add('（已为当前会话加入 PATH: ' + dir + '）');
    }

    final sshRes = await _runShell('ssh -V');
    final sshOut = ((sshRes.stdout as String) + '\n' + (sshRes.stderr as String)).trim();
    if (sshRes.exitCode == 0 || sshOut.contains('OpenSSH')) {
      lines.add('✓ ssh: ' + (sshOut.split('\n').first));
    } else {
      lines.add('✗ ssh 检测失败');
      if (sshOut.isNotEmpty) lines.add(sshOut);
    }

    final rsyncRes = await _runShell('rsync --version');
    final rsyncOut = ((rsyncRes.stdout as String) + '\n' + (rsyncRes.stderr as String)).trim();
    if (rsyncRes.exitCode == 0 || rsyncOut.toLowerCase().contains('rsync')) {
      lines.add('✓ rsync: ' + (rsyncOut.split('\n').first));
    } else {
      lines.add('✗ rsync 检测失败');
      if (rsyncOut.isNotEmpty) lines.add(rsyncOut);
    }

    return lines.join('\n');
  }

  Future<String> fixPermissions() async {
    await _ensureMutagenResolved();
    final path = _mutagenPathOverride;
    if (path == null) {
      return '未找到 mutagen 路径，先运行“检查环境”或安装 mutagen。';
    }

    final buffer = StringBuffer('尝试修复权限：' + path + '\n');

    final quarantine = await _checkQuarantine(path);
    if (quarantine != null) {
      buffer.writeln('检测到隔离标记：' + quarantine);
      buffer.writeln(_shellExample('xattr -d com.apple.quarantine ' + path));
    }

    final removeRes = await Process.run(
      'xattr',
      ['-d', 'com.apple.quarantine', path],
      environment: _augmentedEnv(),
    );
    if (removeRes.exitCode == 0) {
      buffer.writeln('✓ 已移除隔离标记');
    } else {
      final stderrStr = removeRes.stderr?.toString() ?? '';
      final stdoutStr = removeRes.stdout?.toString() ?? '';
      buffer.writeln('✗ 移除隔离标记失败：' + (stderrStr.isNotEmpty ? stderrStr : stdoutStr));
      buffer.writeln('→ 尝试通过系统弹窗请求管理员权限...');
      final elevated = await _runWithPrivileges(['xattr', '-d', 'com.apple.quarantine', path]);
      if (elevated.exitCode == 0) {
        buffer.writeln('✓ 管理员授权后已移除隔离标记');
      } else {
        final elevatedErr = elevated.stderr?.toString().trim();
        final elevatedOut = elevated.stdout?.toString().trim();
        buffer.writeln('✗ 管理员执行仍失败：' + ((elevatedErr?.isNotEmpty ?? false) ? elevatedErr! : (elevatedOut ?? '')));
        buffer.writeln('  请在终端手动执行：');
        buffer.writeln(_shellExample('sudo xattr -d com.apple.quarantine ' + path, label: '    '));
      }
    }

    final chmodRes = await Process.run('chmod', ['+x', path], environment: _augmentedEnv());
    if (chmodRes.exitCode == 0) {
      buffer.writeln('✓ 已确认执行权限');
    }

    final probe = await _mutagen(['version']);
    if (probe.exitCode == 0) {
      buffer.writeln('✓ mutagen version:');
      buffer.writeln(probe.stdout.toString().trim());
    } else {
      buffer.writeln('✗ 仍无法执行：');
      buffer.writeln(_prettyError('mutagen version', probe));
    }

    buffer.writeln('若仍提示 Operation not permitted，请在系统设置→隐私与安全→完全磁盘访问 中给 CodeBiSync 授权。');
    return buffer.toString();
  }

  Future<String> openTerminalForPermissionFix() async {
    await _ensureMutagenResolved();
    final path = _mutagenPathOverride;
    if (path == null) {
      return '未找到 mutagen 路径，先运行“检查环境”或安装 mutagen。';
    }
    final cmd = 'sudo xattr -d com.apple.quarantine ' + _shellEscape(path);
    try {
      // Try to bring up Terminal first; ignore failure if already running.
      await Process.run('open', ['-a', 'Terminal']);

      final args = [
        '-e', 'tell application "Terminal" to activate',
        '-e', 'tell application "Terminal"',
        '-e', 'if (count of windows) is 0 then do script ""',
        '-e', 'do script "' + _escapeForAppleScript(cmd + '; echo; echo \"完成后可关闭此窗口。\"') + '" in front window',
        '-e', 'end tell',
      ];
      // Fire-and-forget so UI不被阻塞（权限对话框或终端执行不会卡住应用）。
      final proc = await Process.start('osascript', args);
      // Detach listeners to avoid holding the process; errors will be reflected by user not seeing Terminal.
      // We still return immediately with instructions.
      // ignore: unawaited_futures
      proc.exitCode;
      return '已请求在 Terminal 中执行：\n' + cmd +
          '\n如果看到权限提示（自动化/控制 Terminal），请点“允许”。若终端未打开，请手动在终端执行上述命令。';
    } on ProcessException catch (e) {
      return '无法调用 osascript/open：${e.message}\n你也可以手动在终端执行：\n' + cmd;
    }
  }

  Future<ProcessResult> _runShell(String command) async {
    try {
      // Login shell to load .zprofile; non-interactive to avoid TTY pgrp errors
      return await Process.run('/bin/zsh', ['-lc', command], environment: _augmentedEnv());
    } on ProcessException catch (e) {
      return ProcessResult(-1, 127, '', 'ProcessException: ${e.message}');
    }
  }

  Future<ProcessResult> _mutagen(List<String> subArgs) async {
    await _ensureMutagenResolved();
    final candidates = <String>[
      if (_mutagenPathOverride != null) _mutagenPathOverride!,
      'mutagen',
      '/opt/homebrew/bin/mutagen',
      '/usr/local/bin/mutagen',
    ];
    ProcessResult? lastResult;
    for (final bin in candidates) {
      try {
        lastResult = await Process.run(bin, subArgs, environment: _augmentedEnv());
        final hasOutput = lastResult.stdout.toString().isNotEmpty || lastResult.stderr.toString().isNotEmpty;
        final isAbsolute = bin.startsWith('/');
        if (lastResult.exitCode == 0 || hasOutput || isAbsolute) {
          // If absolute path was tried, return immediately even on error so caller sees the real reason (e.g. EPERM)
          return lastResult;
        }
      } on ProcessException catch (e) {
        final result = ProcessResult(-1, 126, '', 'ProcessException: ${e.message}');
        if (bin.startsWith('/')) {
          return result;
        }
        lastResult = result;
      }
    }

    // Try via user's shell so PATH and shims apply (login, non-interactive)
    final cmd = (['mutagen', ...subArgs]).map((a) => a.replaceAll("'", "'\\''")).join(' ');
    try {
      final shellRes = await Process.run('/bin/zsh', ['-lc', cmd], environment: _augmentedEnv());
      // If still failing with command not found, attempt to resolve exact path using shell
      if ((shellRes.exitCode == 127) || shellRes.stderr.toString().contains('command not found')) {
        final which = await _runShell('command -v mutagen || true');
        final path = (which.stdout as String).trim();
        if (path.isNotEmpty) {
          try {
            _mutagenPathOverride = path;
            final dir = File(path).parent.path;
            if (!_extraPaths.contains(dir)) _extraPaths.add(dir);
            return await Process.run(path, subArgs, environment: _augmentedEnv());
          } on ProcessException catch (e) {
            return ProcessResult(-1, 127, '', 'ProcessException: ${e.message}');
          }
        }
      }
      return shellRes;
    } on ProcessException catch (e) {
      // Provide a synthetic ProcessResult-like message
      return ProcessResult(-1, 127, '', 'ProcessException: ${e.message}');
    }
  }

  Future<void> _ensureMutagenResolved() async {
    if (_mutagenPathOverride != null) return;

    // First, try command -v with login shell
    final resolved = await _runShell('command -v mutagen || true');
    final path = (resolved.stdout as String).trim();
    if (path.isNotEmpty) {
      _mutagenPathOverride = path;
      final dir = File(path).parent.path;
      if (!_extraPaths.contains(dir)) _extraPaths.add(dir);
      return;
    }

    // Fall back to common install locations
    const fallbackPaths = ['/opt/homebrew/bin/mutagen', '/usr/local/bin/mutagen'];
    for (final candidate in fallbackPaths) {
      if (File(candidate).existsSync()) {
        _mutagenPathOverride = candidate;
        final dir = File(candidate).parent.path;
        if (!_extraPaths.contains(dir)) _extraPaths.add(dir);
        return;
      }
    }
  }

  Future<String?> _checkQuarantine(String path) async {
    final res = await Process.run(
      'xattr',
      ['-p', 'com.apple.quarantine', path],
      environment: _augmentedEnv(),
    );
    if (res.exitCode == 0) {
      final value = res.stdout.toString().trim();
      if (value.isNotEmpty) return value;
    }
    return null;
  }

  void _appendShellExample(List<String> lines, String command, {String label = '  例如：'}) {
    lines.add(_shellExample(command, label: label));
  }

  String _shellExample(String command, {String label = '例如：'}) {
    return '$label$command';
  }

  Future<ProcessResult> _runWithPrivileges(List<String> command) async {
    final escaped = command.map(_shellEscape).join(' ');
    final scriptCommand = '/usr/bin/env ' + escaped;
    final script = 'do shell script "' + _escapeForAppleScript(scriptCommand) + '" with administrator privileges';
    try {
      return await Process.run('osascript', ['-e', script]);
    } on ProcessException catch (e) {
      final msg = e.message?.isNotEmpty == true ? e.message! : e.toString();
      return ProcessResult(-1, 127, '', msg);
    }
  }

  String _shellEscape(String arg) {
    final safe = RegExp(r'^[A-Za-z0-9_@%+=:,./-]+$');
    if (safe.hasMatch(arg)) {
      return arg;
    }
    return "'" + arg.replaceAll("'", "'\\''") + "'";
  }

  String _escapeForAppleScript(String value) {
    return value.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
  }

  String _prettyError(String action, ProcessResult res) {
    final stderrStr = res.stderr?.toString() ?? '';
    final stdoutStr = res.stdout?.toString() ?? '';
    if (stderrStr.contains('command not found') || res.exitCode == 127) {
      final note = _mutagenPathOverride != null ? '（尝试路径: $_mutagenPathOverride）' : '';
      return '未找到 mutagen 可执行程序$note。请安装并确保 PATH 可用\n'
          '建议：brew install mutagen-io/mutagen/mutagen\n'
          '或者把 /opt/homebrew/bin 添加到 PATH。';
    }
    if (res.exitCode == 126 || stderrStr.contains('Permission denied') || stderrStr.contains('Operation not permitted')) {
      final detail = stderrStr.isNotEmpty ? stderrStr : stdoutStr;
      final candidate = _mutagenPathOverride ?? 'mutagen';
      final commandPath = candidate.contains(' ') ? "'${candidate.replaceAll("'", "'\\''")}'" : candidate;
      final manualCmd = _shellExample('xattr -d com.apple.quarantine ' + commandPath);
      return '无法执行 $candidate：${detail.isEmpty ? 'Operation not permitted' : detail}\n'
          '$manualCmd\n'
          '并在系统设置中授予应用“完全磁盘访问”权限。';
    }
    if (stderrStr.contains('Operation not permitted')) {
      return '无法执行 $action：Operation not permitted\n'
          '可能原因：系统未允许该进程执行或缺少权限。\n'
          '建议：\n'
          '- 在终端里确认 mutagen 可运行（mutagen version）\n'
          '- 若用 Homebrew 安装，执行：xattr -d com.apple.quarantine \$(which mutagen)\n'
          '- 确认应用拥有磁盘访问权限（系统设置→隐私与安全→完全磁盘访问）。';
    }
    final combined = [stdoutStr, stderrStr].where((s) => s.trim().isNotEmpty).join('\n');
    return combined.isEmpty ? '执行 $action 失败（exit=${res.exitCode}）' : combined;
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
