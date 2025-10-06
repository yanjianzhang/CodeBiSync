import 'dart:io';

class SyncConfig {
  String? localPath;
  String? remoteUser;
  String? remoteHost;
  String? remotePath;

  SyncConfig({this.localPath, this.remoteUser, this.remoteHost, this.remotePath});

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

  void updateConfig({String? localPath, String? remoteUser, String? remoteHost, String? remotePath}) {
    if (localPath != null) config.localPath = localPath;
    if (remoteUser != null) config.remoteUser = remoteUser;
    if (remoteHost != null) config.remoteHost = remoteHost;
    if (remotePath != null) config.remotePath = remotePath;
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

  Future<void> up() async {
    if (!config.isComplete) {
      throw StateError('配置不完整：需要本地目录、远程用户名、远端名称、远程目录');
    }

    final local = config.localPath!;
    final remoteSpec = '${config.remoteUser}@${config.remoteHost}:${config.remotePath}';

    // Check existing sessions
    final listResult = await Process.run('mutagen', ['sync', 'list']);
    if (listResult.exitCode == 0 && listResult.stdout.toString().contains(_sessionName)) {
      await Process.run('mutagen', ['sync', 'resume', _sessionName]);
    } else {
      await Process.run('mutagen', [
        'sync',
        'create',
        '--name', _sessionName,
        '--sync-mode=two-way-resolved',
        '--ignore-vcs',
        local,
        remoteSpec,
      ]);
    }
  }

  Future<String> status() async {
    final res = await Process.run('mutagen', ['sync', 'list']);
    if (res.exitCode != 0) {
      return 'Error: ${res.stderr}';
    }
    return res.stdout.toString();
  }
}
