import 'dart:io';

import '../endpoint.dart';
import '../staging_models.dart';
import '../differ.dart';
import '../snapshot.dart';

class RsyncEndpoint implements Endpoint {
  final String host;
  final String user;
  final int port;
  final String remoteRoot;
  final String? identityFile;

  // Local source (Alpha root). We push from this path to remote.
  final String localRoot;

  RsyncEndpoint({
    required this.host,
    required this.user,
    required this.remoteRoot,
    required this.localRoot,
    this.port = 22,
    this.identityFile,
  });

  @override
  Future<Snapshot> scan() async {
    // Remote scanning via rsync --list-only is available in RsyncService, but here we
    // return an empty snapshot to avoid heavy remote calls in the main session loop.
    // The UI's remote browser uses RsyncService directly.
    return Snapshot({});
  }

  @override
  Future<void> apply(StagingData staging) async {
    // For each change, push via rsync. Handle deletes using ssh rm -rf.
    for (final ch in staging.metadataChanges) {
      final rel = ch.path;
      switch (ch.type) {
        case ChangeType.Create:
        case ChangeType.Modify:
          if (ch.metadata?.isDirectory == true) {
            await _ssh(['mkdir', '-p', _remotePath(rel)]);
          } else {
            await _ensureRemoteDir(rel);
            await _rsyncFile(rel);
          }
          break;
        case ChangeType.Delete:
          await _ssh(['rm', '-rf', _remotePath(rel)]);
          break;
        case ChangeType.Rename:
          final old = ch.oldPath;
          if (old != null && old.isNotEmpty) {
            await _ssh(['mkdir', '-p', _remotePath(_dirname(rel))]);
            await _ssh(['mv', _remotePath(old), _remotePath(rel)]);
          } else {
            // Fallback to copy
            await _ensureRemoteDir(rel);
            await _rsyncFile(rel);
          }
          break;
        case ChangeType.MetadataChange:
          // ignore for now
          break;
      }
    }
  }

  // Pull a single relative path from remote -> localRoot (used for beta→alpha)
  Future<void> pull(String relPath) async {
    final src = '$user@$host:${_quote(_remotePath(relPath))}';
    final destDir = _join(localRoot, _dirname(relPath));
    await Directory(destDir).create(recursive: true);

    final sshArgs = [
      'ssh',
      '-p', port.toString(),
      '-o', 'StrictHostKeyChecking=no',
      '-o', 'UserKnownHostsFile=/dev/null',
      '-o', 'BatchMode=yes',
      if (identityFile != null && identityFile!.isNotEmpty) ...['-i', identityFile!],
    ];

    final args = [
      '-av',
      '-e', sshArgs.join(' '),
      src,
      '$destDir/',
    ];
    final res = await Process.run('rsync', args);
    if (res.exitCode != 0) {
      throw ProcessException('rsync', args, res.stderr, res.exitCode);
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
    await _ssh(['mkdir', '-p', _remotePath(_dirname(newPath))]);
    await _ssh(['mv', _remotePath(oldPath), _remotePath(newPath)]);
  }

  @override
  Future<void> setMetadata(String path, FileMetadata metadata) async {
    // optional: implement touch -m to set mtime
  }

  // Helpers
  Future<void> _ensureRemoteDir(String relPath) async {
    final dir = _dirname(relPath);
    if (dir.isNotEmpty) {
      await _ssh(['mkdir', '-p', _remotePath(dir)]);
    }
  }

  Future<void> _rsyncFile(String relPath) async {
    final src = _join(localRoot, relPath);
    final destDir = _remotePath(_dirname(relPath));
    final userAtHost = '$user@$host';
    final sshArgs = [
      'ssh',
      '-p', port.toString(),
      '-o', 'StrictHostKeyChecking=no',
      '-o', 'UserKnownHostsFile=/dev/null',
      '-o', 'BatchMode=yes',
      if (identityFile != null && identityFile!.isNotEmpty) ...['-i', identityFile!],
    ];

    final args = [
      '-av',
      '-e', sshArgs.join(' '),
      src,
      '$userAtHost:${_quote(destDir)}/',
    ];
    final res = await Process.run('rsync', args);
    if (res.exitCode != 0) {
      throw ProcessException('rsync', args, res.stderr, res.exitCode);
    }
  }

  Future<void> _ssh(List<String> cmdArgs) async {
    final args = <String>[
      '-p', port.toString(),
      '-o', 'StrictHostKeyChecking=no',
      '-o', 'UserKnownHostsFile=/dev/null',
      '-o', 'BatchMode=yes',
      if (identityFile != null && identityFile!.isNotEmpty) ...['-i', identityFile!],
      '$user@$host',
      ...cmdArgs,
    ];
    final res = await Process.run('ssh', args);
    if (res.exitCode != 0) {
      throw ProcessException('ssh', args, res.stderr, res.exitCode);
    }
  }

  String _remotePath(String rel) {
    if (rel.isEmpty) return remoteRoot;
    final base = remoteRoot.endsWith('/') ? remoteRoot.substring(0, remoteRoot.length - 1) : remoteRoot;
    return '$base/$rel';
  }

  static String _dirname(String rel) {
    final idx = rel.lastIndexOf('/');
    return idx > 0 ? rel.substring(0, idx) : '';
  }

  static String _join(String a, String b) => a.endsWith('/') ? a + b : '$a/$b';
  static String _quote(String s) => s.contains(' ') ? '"${s.replaceAll('"', '\\"')}"' : s;
}
