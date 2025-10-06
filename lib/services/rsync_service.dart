import 'dart:io';

class RsyncEntry {
  final String name;
  final bool isDirectory;

  const RsyncEntry(this.name, this.isDirectory);
}

class RsyncService {
  static Future<List<RsyncEntry>> list({
    required String host,
    required String username,
    required String path,
    int port = 22,
    String? identityFile,
    String? proxyJump,
    bool compression = false,
    bool forwardAgent = false,
    bool immediateOnly = true,
    bool dirsOnly = true,
    List<String> include = const [],
    List<String> exclude = const [],
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final normalizedPath = path.isEmpty ? '/' : path;
    final base = normalizedPath.endsWith('/') ? normalizedPath : '$normalizedPath/';
    final remoteSpec = '${username.isNotEmpty ? '$username@' : ''}$host:${_quotePath(base)}';

    final sshArgs = <String>[
      'ssh',
      '-p', port.toString(),
      '-o', 'StrictHostKeyChecking=no',
      '-o', 'UserKnownHostsFile=/dev/null',
      '-o', 'BatchMode=yes',
      if (compression) '-C',
      if (forwardAgent) '-A',
      if (proxyJump != null && proxyJump.isNotEmpty) ...['-J', proxyJump],
      if (identityFile != null && identityFile.isNotEmpty) ...['-i', identityFile],
    ];

    final args = <String>[
      '-av',
      '--list-only',
      '-e', sshArgs.join(' '),
      if (immediateOnly) ...['--exclude', '*/**'],
      for (final inc in include) ...['--include', inc],
      for (final exc in exclude) ...['--exclude', exc],
      remoteSpec,
    ];

    // Fast preflight: ssh connectivity with a short timeout, fail fast if blocked
    try {
      final preArgs = <String>[
        '-p', port.toString(),
        '-o', 'ConnectTimeout=${timeout.inSeconds}',
        '-o', 'BatchMode=yes',
        '-o', 'StrictHostKeyChecking=no',
        '-o', 'UserKnownHostsFile=/dev/null',
        if (compression) '-C',
        if (forwardAgent) '-A',
        if (proxyJump != null && proxyJump.isNotEmpty) ...['-J', proxyJump],
        if (identityFile != null && identityFile.isNotEmpty) ...['-i', identityFile],
        '${username.isNotEmpty ? '$username@' : ''}$host', 'printf', 'ok',
      ];
      final pre = await Process.run('ssh', preArgs);
      // If preflight fails (some bastions close trivial commands), continue to rsync which
      // launches rsync --server remotely and often succeeds even if preflight doesn't.
    } catch (_) {}

    final process = await Process.start('rsync', args);
    final outBuf = StringBuffer();
    final errBuf = StringBuffer();
    process.stdout.transform(SystemEncoding().decoder).listen(outBuf.write);
    process.stderr.transform(SystemEncoding().decoder).listen(errBuf.write);
    final exit = await process.exitCode.timeout(timeout, onTimeout: () {
      process.kill(ProcessSignal.sigkill);
      return -1;
    });
    if (exit != 0) {
      throw ProcessException('rsync', args, errBuf.toString().isEmpty ? outBuf.toString() : errBuf.toString(), exit);
    }

    final entries = <RsyncEntry>[];
    final lines = outBuf.toString().split(RegExp(r'\r?\n'));
    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('sending incremental file list') ||
          line.startsWith('receiving incremental file list') ||
          line.startsWith('total size is') ||
          line.startsWith('total transferred')) {
        continue;
      }
      final match = _entryPattern.firstMatch(line);
      if (match == null) continue;
      final typeChar = match.group(1) ?? '-';
      final name = match.group(2)?.trim() ?? '';
      if (name.isEmpty || name == '.' || name == './') continue;
      final isDir = typeChar == 'd';
      if (dirsOnly && !isDir) continue;
      entries.add(RsyncEntry(name, isDir));
    }
    return entries;
  }

  static final _entryPattern = RegExp(
    r'^([dl-])[rwxstST-]{9}\s+\S+\s+\d{4}/\d{2}/\d{2}\s+\d{2}:\d{2}:\d{2}\s+(.*)$',
  );

  static String _quotePath(String path) {
    final escaped = path.replaceAll('"', '\\"');
    return '"$escaped"';
  }
}
