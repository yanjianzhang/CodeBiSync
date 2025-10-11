import 'dart:io';

import 'package:path/path.dart' as p;

import '../endpoint.dart';
import '../staging_models.dart';
import '../sync_controller.dart';
import '../differ_models.dart';
import '../snapshot.dart';
import '../../services/connection_daemon.dart';
import '../../services/rsync_service.dart';
import '../../services/sync_status_manager.dart';

class RsyncEndpoint implements RemoteIncrementalEndpoint, PullableEndpoint {
  final String host;
  final String user;
  final int port;
  late final String remoteRoot; // Changed to late final
  final String? identityFile;
  final String localRoot;
  final String? proxyJump;
  final bool compression;
  final bool forwardAgent;
  final SyncStatusManager? statusManager; // 新增状态管理器
  final List<String> excludes; // 添加排除规则

  static const int _maxIncrementalPaths = 2048;
  static final RegExp _rsyncListPattern = RegExp(
    r'^([dl-])[rwxstST-]{9}\s+(\d+)\s+(\d{4}/\d{2}/\d{2})\s+(\d{2}:\d{2}:\d{2})\s+(.*)$',
  );

  final p.Context _posix = p.posix;

  late final String _remoteRootCanonical;
  late final String _localRootCanonical;
  final ConnectionDaemon _connectionDaemon = ConnectionDaemon();

  RsyncEndpoint({
    required this.host,
    required this.user,
    required String remoteRoot,
    required String localRoot,
    this.port = 22,
    this.identityFile,
    this.proxyJump,
    this.compression = false,
    this.forwardAgent = false,
    this.statusManager,
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
  }) : localRoot = p.normalize(localRoot) {
    this.remoteRoot = _normalizeRemote(remoteRoot);
    _remoteRootCanonical = _normalizeRemote(remoteRoot);
    _localRootCanonical = Directory(localRoot).absolute.path;
    Directory(_localRootCanonical).createSync(recursive: true);

    // 注册连接到守护进程以提高稳定性
    _connectionDaemon.registerConnection(
      host: host,
      username: user,
      port: port,
      privateKeyPath: identityFile,
      proxyJump: proxyJump,
      compression: compression,
      forwardAgent: forwardAgent,
    );
  }

  @override
  Future<Snapshot> scan() async {
    statusManager?.addEvent(SyncOperation.scanFiles, '扫描远程文件系统');

    try {
      final args = [
        '-e',
        _sshCommandString(),
        '${_userAtHost()}:${_quote(remoteRoot)}',
      ];
      final res = await Process.run('rsync', ['--list-only', '--recursive', ...args]);
      if (res.exitCode != 0) {
        throw Exception('rsync list failed: ${res.stderr}');
      }

      final entries = <String, FileMetadata>{};
      final lines = (res.stdout as String).split('\n');
      for (final line in lines) {
        final m = _rsyncListPattern.firstMatch(line);
        if (m != null) {
          final typeChar = m[1]!;
          final sizeStr = m[2]!;
          final dateStr = m[3]!;
          final timeStr = m[4]!;
          var name = m[5]!;
          
          // 过滤掉.codebisync目录及其内容
          if (name.contains('.codebisync')) {
            continue;
          }
          
          final isDir = typeChar == 'd';
          if (name.endsWith('/')) {
            name = name.substring(0, name.length - 1);
          }
          final size = int.tryParse(sizeStr) ?? 0;
          final timestamp =
              DateTime.tryParse('${dateStr.replaceAll('/', '-')}T$timeStr') ??
                  DateTime.now();

          entries[name] = FileMetadata(
            path: name,
            isDirectory: isDir,
            size: isDir ? 0 : size,
            mtime: timestamp,
          );
        }
      }

      statusManager?.addEvent(SyncOperation.scanFiles, '远程文件扫描完成', isComplete: true);
      return Snapshot(entries);
    } catch (e) {
      statusManager?.addEvent(SyncOperation.scanFiles, '远程文件扫描失败', isComplete: true);
      rethrow;
    }
  }

  @override
  Future<Snapshot> refreshSnapshot({
    required Snapshot previous,
    required Set<String> relativePaths,
  }) async {
    if (relativePaths.isEmpty) {
      return previous;
    }

    if (relativePaths.any((e) => e.isEmpty)) {
      return await scan();
    }

    final normalized = _normalizeHints(relativePaths);
    if (normalized.contains('')) {
      return await scan();
    }

    final next = Map<String, FileMetadata>.from(previous.entries);
    for (final rel in normalized) {
      next.remove(rel);
      _removeSubtree(next, rel);
      final sub = await _listSubtree(rel);
      next.addAll(sub);
    }
    return Snapshot(next);
  }

  @override
  Future<RemoteChangeBatch> detectRemoteChanges({
    Snapshot? previous,
    bool forceFull = false,
  }) async {
    if (forceFull || previous == null) {
      return RemoteChangeBatch.fullRescan();
    }

    final localDir = Directory(_localRootCanonical);
    if (!localDir.existsSync()) {
      return RemoteChangeBatch.fullRescan();
    }

    final args = <String>[
      '-av',
      '--dry-run',
      '--delete',
      '--itemize-changes',
      '-e',
      _sshCommandString(),
      '${_userAtHost()}:${_quote(_ensureTrailingSlash(_remoteRootCanonical))}',
      _ensureTrailingSlash(_localRootCanonical),
    ];

    final result = await Process.run('rsync', args);
    if (result.exitCode != 0) {
      return RemoteChangeBatch.fullRescan();
    }

    final changed = <String>{};
    final lines = result.stdout.toString().split(RegExp(r'\r?\n'));
    for (final line in lines) {
      final trimmed = line.trimRight();
      if (trimmed.isEmpty) continue;
      if (trimmed.startsWith('sending incremental file list') ||
          trimmed.startsWith('sent ') ||
          trimmed.startsWith('total size is')) {
        continue;
      }
      if (trimmed.startsWith('*deleting ')) {
        final path = _normalizeRemoteRelative(trimmed.substring(10).trim());
        if (path.isEmpty) {
          return RemoteChangeBatch.fullRescan();
        }
        changed.add(path);
        continue;
      }
      if (trimmed.length <= 12) continue;
      final summary = trimmed.substring(0, 11);
      final pathPart = trimmed.substring(12).trim();
      if (pathPart.isEmpty) continue;
      final indicator = summary[0];
      if (indicator == '>' || indicator == 'c' || indicator == '*') {
        final path = _normalizeRemoteRelative(pathPart);
        if (path.isEmpty) {
          return RemoteChangeBatch.fullRescan();
        }
        changed.add(path);
      }
    }

    if (changed.isEmpty) {
      return RemoteChangeBatch.empty();
    }
    if (changed.length > _maxIncrementalPaths) {
      return RemoteChangeBatch.fullRescan();
    }

    final expanded = _expandWithParents(changed);
    return RemoteChangeBatch(requiresFullRescan: false, paths: expanded);
  }

  @override
  Future<void> apply(StagingData staging) async {
    for (final change in staging.metadataChanges) {
      final rel = _normalizeRemoteRelative(change.path);
      switch (change.type) {
        case ChangeType.create:
        case ChangeType.modify:
          if (change.metadata?.isDirectory == true) {
            statusManager?.addEvent(SyncOperation.createDirectory, rel, filePath: rel);
            await _ssh(['mkdir', '-p', _remotePath(rel)]);
            // 验证目录是否创建成功
            if (!(await verifyRemotePathExists(rel, isDirectory: true))) {
              statusManager?.addEvent(SyncOperation.createDirectory, '创建失败: $rel',
                  isComplete: true, filePath: rel);
              throw Exception('Failed to create remote directory: $rel');
            }
            statusManager?.addEvent(SyncOperation.createDirectory, rel,
                isComplete: true, filePath: rel);
          } else {
            statusManager?.addEvent(SyncOperation.uploadFile, rel, filePath: rel);
            await _ensureRemoteDir(rel);
            // 使用rsync传输文件
            await rsyncFile(rel);
            // 验证文件是否传输成功
            if (!(await verifyRemotePathExists(rel, isDirectory: false))) {
              statusManager?.addEvent(SyncOperation.uploadFile, '传输失败: $rel',
                  isComplete: true, filePath: rel);
              throw Exception('Failed to sync file: $rel');
            }
            statusManager?.addEvent(SyncOperation.uploadFile, rel,
                isComplete: true, filePath: rel);
          }
          break;
        case ChangeType.delete:
          statusManager?.addEvent(SyncOperation.deletePath, rel, filePath: rel);
          await _ssh(['rm', '-rf', _remotePath(rel)]);
          // 验证文件是否删除成功
          if (await verifyRemotePathExists(rel, isDirectory: null)) {
            statusManager?.addEvent(SyncOperation.deletePath, '删除失败: $rel',
                isComplete: true, filePath: rel);
            throw Exception('Failed to delete remote path: $rel');
          }
          statusManager?.addEvent(SyncOperation.deletePath, rel,
              isComplete: true, filePath: rel);
          break;
        case ChangeType.rename:
          final old = change.oldPath;
          if (old != null && old.isNotEmpty) {
            statusManager?.addEvent(SyncOperation.renamePath, '$old -> $rel', filePath: rel);
            final oldNorm = _normalizeRemoteRelative(old);
            await _ssh(['mkdir', '-p', _remotePath(_posix.dirname(rel))]);
            await _ssh(['mv', _remotePath(oldNorm), _remotePath(rel)]);
            // 验证重命名是否成功
            if (!(await verifyRemotePathExists(rel, isDirectory: null)) ||
                await verifyRemotePathExists(oldNorm, isDirectory: null)) {
              statusManager?.addEvent(
                  SyncOperation.renamePath, '重命名失败: $old -> $rel',
                  isComplete: true, filePath: rel);
              throw Exception(
                  'Failed to rename remote path from $oldNorm to $rel');
            }
            statusManager?.addEvent(SyncOperation.renamePath, '$old -> $rel',
                isComplete: true, filePath: rel);
          } else {
            statusManager?.addEvent(SyncOperation.uploadFile, rel, filePath: rel);
            await _ensureRemoteDir(rel);
            await rsyncFile(rel);
            // 验证文件是否传输成功
            if (!(await verifyRemotePathExists(rel, isDirectory: false))) {
              statusManager?.addEvent(SyncOperation.uploadFile, '传输失败: $rel',
                  isComplete: true, filePath: rel);
              throw Exception('Failed to sync file: $rel');
            }
            statusManager?.addEvent(SyncOperation.uploadFile, rel,
                isComplete: true, filePath: rel);
          }
          break;
        case ChangeType.metadataChange:
          break;
      }
    }
  }

  // 验证远程路径是否存在
  Future<bool> verifyRemotePathExists(String relPath,
      {bool? isDirectory}) async {
    statusManager?.addEvent(SyncOperation.verifyRemote, relPath);

    final normPath = _normalizeRemoteRelative(relPath);
    final checkCmd = isDirectory != null
        ? ['test', '-${isDirectory ? 'd' : 'f'}', _remotePath(normPath)]
        : ['test', '-e', _remotePath(normPath)];

    try {
      final result = await _ssh(checkCmd, throwOnError: false);

      // 验证完成
      statusManager?.addEvent(SyncOperation.verifyRemote, relPath,
          isComplete: true);

      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<ProcessResult> _ssh(List<String> cmdArgs,
      {bool throwOnError = true}) async {
    final args = <String>[
      '-p',
      port.toString(),
      '-o',
      'StrictHostKeyChecking=no',
      '-o',
      'UserKnownHostsFile=/dev/null',
      '-o',
      'BatchMode=yes',
      if (identityFile != null && identityFile!.isNotEmpty) ...[
        '-i',
        identityFile!
      ],
      '$user@$host',
      ...cmdArgs,
    ];
    final res = await Process.run('ssh', args);
    if (throwOnError && res.exitCode != 0) {
      throw ProcessException('ssh', args, res.stderr, res.exitCode);
    }
    return res;
  }

  // 增强的rsync文件传输方法
  Future<void> rsyncFile(String relPath) async {
    statusManager?.addEvent(SyncOperation.uploadFile, relPath, filePath: relPath);

    try {
      final src = _joinLocal(_localRootCanonical, relPath);
      final destDir = _remotePath(_posix.dirname(relPath));
      final userAtHost = '$user@$host';
      final sshArgs = [
        'ssh',
        '-p',
        port.toString(),
        '-o',
        'StrictHostKeyChecking=no',
        '-o',
        'UserKnownHostsFile=/dev/null',
        '-o',
        'BatchMode=yes',
        if (identityFile != null && identityFile!.isNotEmpty) ...[
          '-i',
          identityFile!
        ],
      ];

      // 添加校验和比较和详细输出
      final args = <String>[
        '-avz', // 添加压缩以提高传输效率
        '--checksum', // 使用校验和比较文件，确保完全一致
        '--progress', // 显示传输进度
        '--chmod=ugo=rwX', // 确保适当的权限
        '--times', // 保留修改时间
        '-e', sshArgs.join(' '),
        src,
        '$userAtHost:${_quote(destDir)}/',
      ];
      final res = await Process.run('rsync', args);
      if (res.exitCode != 0) {
        throw ProcessException('rsync', args, res.stderr, res.exitCode);
      }

      // 上传完成
      statusManager?.addEvent(SyncOperation.uploadFile, relPath,
          isComplete: true, filePath: relPath);
    } catch (e) {
      // 添加失败状态记录
      statusManager?.addEvent(SyncOperation.uploadFile, '传输失败: $relPath',
          isComplete: true, filePath: relPath);
      rethrow;
    }
  }

  // 修改pull方法以记录下载状态
  @override
  Future<void> pull(String relPath) async {
    statusManager?.addEvent(SyncOperation.downloadFile, relPath, filePath: relPath);

    try {
      final rel = _normalizeRemoteRelative(relPath);
      final src = '${_userAtHost()}:${_quote(_remotePath(rel))}';
      final destDir =
          Directory(_joinLocal(_localRootCanonical, _posix.dirname(rel)));
      await destDir.create(recursive: true);

      final args = [
        '-av',
        '-e',
        _sshCommandString(),
        src,
        '${_joinLocal(_localRootCanonical, _posix.dirname(rel))}/',
      ];

      final result = await Process.run('rsync', args);
      if (result.exitCode != 0) {
        throw ProcessException('rsync', args, result.stderr, result.exitCode);
      }

      // 下载完成
      statusManager?.addEvent(SyncOperation.downloadFile, relPath,
          isComplete: true, filePath: relPath);
    } catch (e) {
      // 添加失败状态记录
      statusManager?.addEvent(SyncOperation.downloadFile, '下载失败: $relPath',
          isComplete: true, filePath: relPath);
      rethrow;
    }
  }

  @override
  Future<List<int>> readChunk(String path, int offset, int length) async {
    throw UnimplementedError();
  }

  @override
  Future<void> writeChunk(String path, int offset, List<int> chunk) async {
    throw UnimplementedError();
  }

  @override
  Future<void> delete(String path) async {
    await _ssh(['rm', '-rf', _remotePath(path)]);
  }

  @override
  Future<void> rename(String oldPath, String newPath) async {
    await _ssh(['mkdir', '-p', _remotePath(_posix.dirname(newPath))]);
    await _ssh(['mv', _remotePath(oldPath), _remotePath(newPath)]);
  }

  @override
  Future<void> setMetadata(String path, FileMetadata metadata) async {
    // Intentionally left as no-op for now.
  }

  Future<Map<String, FileMetadata>> _listSubtree(String rel) async {
    if (rel.isEmpty) {
      final res = await _runRsyncList('', treatAsDirectory: true);
      return res ?? {};
    }

    final normalized = _normalizeRemoteRelative(rel);
    final dirRes = await _runRsyncList(normalized, treatAsDirectory: true);
    if (dirRes != null) {
      return dirRes;
    }

    final fileRes = await _runRsyncList(normalized, treatAsDirectory: false);
    return fileRes ?? {};
  }

  Future<Map<String, FileMetadata>?> _runRsyncList(String rel,
      {required bool treatAsDirectory}) async {
    final target =
        '${_userAtHost()}:${_quote(_remoteListTarget(rel, treatAsDirectory))}';
    final args = [
      '-av',
      '--list-only',
      '-e',
      _sshCommandString(),
      target,
    ];
    final result = await Process.run('rsync', args);
    if (result.exitCode != 0) {
      if (treatAsDirectory) {
        return null;
      }
      final stderr = result.stderr.toString();
      if (stderr.contains('No such file or directory')) {
        return {};
      }
      throw ProcessException('rsync', args, result.stderr, result.exitCode);
    }
    final stdout = result.stdout.toString();
    return _parseRsyncListing(stdout, rel);
  }

  Map<String, FileMetadata> _parseRsyncListing(String stdout, String baseRel) {
    final out = <String, FileMetadata>{};
    final base = _normalizeRemoteRelative(baseRel);
    final lines = stdout.split(RegExp(r'\r?\n'));
    for (final raw in lines) {
      final line = raw.trimRight();
      if (line.isEmpty) continue;
      if (line.startsWith('receiving incremental file list') ||
          line.startsWith('sending incremental file list') ||
          line.startsWith('total size is') ||
          line.startsWith('sent ') ||
          line.startsWith('total file size')) {
        continue;
      }
      final match = _rsyncListPattern.firstMatch(line);
      if (match == null) continue;
      final typeChar = match.group(1)!;
      final sizeStr = match.group(2)!;
      final dateStr = match.group(3)!;
      final timeStr = match.group(4)!;
      var name = match.group(5)!.trim();
      if (name.isEmpty) continue;
      if (name == '.' || name == './') {
        if (base.isEmpty) continue;
        name = base;
      } else {
        if (name.startsWith('./')) {
          name = name.substring(2);
        }
        if (name.endsWith('/')) {
          name = name.substring(0, name.length - 1);
        }
        name = base.isEmpty ? name : _posix.join(base, name);
      }
      final normalized = _normalizeRemoteRelative(name);
      if (normalized.isEmpty) continue;
      final isDir = typeChar == 'd';
      final size = int.tryParse(sizeStr) ?? 0;
      final timestamp =
          DateTime.tryParse('${dateStr.replaceAll('/', '-')}T$timeStr') ??
              DateTime.now();

      out[normalized] = FileMetadata(
        path: normalized,
        isDirectory: isDir,
        size: isDir ? 0 : size,
        mtime: timestamp,
        checksum: null,
      );
    }
    return out;
  }

  void _removeSubtree(Map<String, FileMetadata> map, String rel) {
    if (rel.isEmpty) {
      map.clear();
      return;
    }
    final prefix = rel.endsWith('/') ? rel : '$rel/';
    final toRemove = <String>[];
    map.forEach((key, _) {
      if (key == rel || key.startsWith(prefix)) {
        toRemove.add(key);
      }
    });
    for (final key in toRemove) {
      map.remove(key);
    }
  }

  Set<String> _normalizeHints(Set<String> inputs) {
    final out = <String>{};
    for (var raw in inputs) {
      final norm = _normalizeRemoteRelative(raw);
      if (norm.isEmpty) {
        out.clear();
        out.add('');
        return out;
      }
      out.add(norm);
    }
    return out;
  }

  Set<String> _expandWithParents(Set<String> inputs) {
    final out = <String>{};
    for (final path in inputs) {
      final norm = _normalizeRemoteRelative(path);
      if (norm.isEmpty) continue;
      out.add(norm);
      var parent = _posix.dirname(norm);
      while (parent.isNotEmpty && parent != '.' && parent != '/') {
        out.add(parent);
        parent = _posix.dirname(parent);
      }
    }
    return out;
  }

  String _remoteListTarget(String rel, bool treatAsDirectory) {
    if (rel.isEmpty) {
      return _ensureTrailingSlash(_remoteRootCanonical);
    }
    final abs = _remotePath(rel);
    return treatAsDirectory ? _ensureTrailingSlash(abs) : abs;
  }

  String _remotePath(String rel) {
    final normalized = _normalizeRemoteRelative(rel);
    if (normalized.isEmpty) {
      return _remoteRootCanonical;
    }
    return _ensureNoDuplicateSlashes('$_remoteRootCanonical/$normalized');
  }

  Future<void> _ensureRemoteDir(String relPath) async {
    final dir = _posix.dirname(relPath);
    if (dir.isEmpty || dir == '.') return;
    await _ssh(['mkdir', '-p', _remotePath(dir)]);
  }

  List<String> _sshCommandArgs() {
    return <String>[
      '-p',
      port.toString(),
      '-o',
      'StrictHostKeyChecking=no',
      '-o',
      'UserKnownHostsFile=/dev/null',
      '-o',
      'BatchMode=yes',
      if (identityFile != null && identityFile!.isNotEmpty) ...[
        '-i',
        identityFile!
      ],
    ];
  }

  String _sshCommandString() {
    final args = ['ssh', ..._sshCommandArgs()];
    return args.join(' ');
  }

  String _userAtHost() => user.isEmpty ? host : '$user@$host';

  String _normalizeRemote(String input) {
    var value = input.trim();
    if (value.isEmpty) {
      return '/';
    }
    value = value.replaceAll(RegExp(r'/+$'), '');
    if (value.isEmpty) {
      return '/';
    }
    return _ensureNoDuplicateSlashes(value);
  }

  String _normalizeRemoteRelative(String input) {
    var value = input.trim();
    if (value.startsWith('./')) {
      value = value.substring(2);
    }
    value = value.replaceAll('\\', '/');
    value = value.replaceAll(RegExp(r'/'), '/');
    if (value == '.' || value == '/') {
      return '';
    }
    if (value.startsWith('/')) {
      value = value.substring(1);
    }
    final normalized = _posix.normalize(value);
    if (normalized == '.' || normalized == '/') {
      return '';
    }
    if (normalized.startsWith('../')) {
      return '';
    }
    return normalized;
  }

  String _ensureTrailingSlash(String input) =>
      input.endsWith('/') ? input : '$input/';

  String _ensureNoDuplicateSlashes(String input) =>
      input.replaceAll(RegExp(r'//+'), '/');

  String _joinLocal(String base, String rel) {
    if (rel.isEmpty || rel == '.' || rel == '/') {
      return base;
    }
    return p.normalize(p.join(base, rel));
  }

  String _quote(String value) {
    if (!value.contains(' ')) return value;
    return '"${value.replaceAll('"', '\\"')}"';
  }
}
