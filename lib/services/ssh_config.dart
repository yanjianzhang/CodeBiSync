import 'dart:io';

class SshConfigHost {
  final String host; // Alias in config's Host
  final String? hostName; // Real host name
  final String? user;
  final int? port;
  final List<String> identityFiles;
  final String? proxyJump;
  final bool compression;
  final bool forwardAgent;

  SshConfigHost({
    required this.host,
    this.hostName,
    this.user,
    this.port,
    this.identityFiles = const [],
    this.proxyJump,
    this.compression = false,
    this.forwardAgent = false,
  });
}

class SshConfigParser {
  static List<SshConfigHost> parse(String content) {
    final lines = content.split(RegExp(r'\r?\n'));
    final hosts = <SshConfigHost>[];
    String? currentHost;
    String? hostName;
    String? user;
    int? port;
    final identityFiles = <String>[];
    String? proxyJump;

    bool compression = false;
    bool forwardAgent = false;

    void flush() {
      if (currentHost != null) {
        hosts.add(SshConfigHost(
          host: currentHost!,
          hostName: hostName,
          user: user,
          port: port,
          identityFiles: List.unmodifiable(identityFiles),
          proxyJump: proxyJump,
          compression: compression,
          forwardAgent: forwardAgent,
        ));
      }
      currentHost = null;
      hostName = null;
      user = null;
      port = null;
      identityFiles.clear();
      proxyJump = null;
      compression = false;
      forwardAgent = false;
    }

    for (var raw in lines) {
      var line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final idx = line.indexOf(RegExp(r'\s'));
      String key;
      String value;
      if (idx <= 0) {
        key = line.toLowerCase();
        value = '';
      } else {
        key = line.substring(0, idx).toLowerCase();
        value = line.substring(idx).trim();
      }
      switch (key) {
        case 'host':
          // Only keep simple alias (no spaces/wildcards) — pick the first token
          final alias = value.split(RegExp(r'\s+')).first;
          if (currentHost != null) flush();
          // Ignore wildcard hosts like * for simplicity
          if (alias.contains('*') || alias.contains('?')) {
            currentHost = null;
            continue;
          }
          currentHost = alias;
          break;
        case 'hostname':
          hostName = value;
          break;
        case 'user':
          user = value;
          break;
        case 'port':
          port = int.tryParse(value);
          break;
        case 'identityfile':
          // May contain multiple files in one line
          final files = value.split(RegExp(r'\s+')).where((e) => e.isNotEmpty);
          identityFiles.addAll(files.map(_expandHome));
          break;
        case 'proxyjump':
          proxyJump = value;
          break;
        case 'compression':
          compression = _toBool(value);
          break;
        case 'forwardagent':
          forwardAgent = _toBool(value);
          break;
      }
    }
    // Flush last
    flush();
    return hosts;
  }

  static String _expandHome(String path) {
    if (path.startsWith('~')) {
      final home = Platform.environment['HOME'] ?? '';
      if (home.isNotEmpty) {
        return path.replaceFirst('~', home);
      }
    }
    return path;
  }

  static bool _toBool(String v) {
    switch (v.toLowerCase()) {
      case 'yes':
      case 'true':
      case '1':
        return true;
      default:
        return false;
    }
  }
}

Future<List<SshConfigHost>> loadDefaultSshConfig() async {
  try {
    final home = Platform.environment['HOME'];
    if (home == null) return [];
    final file = File('$home/.ssh/config');
    if (!await file.exists()) return [];
    final content = await file.readAsString();
    return SshConfigParser.parse(content);
  } catch (_) {
    return [];
  }
}

/// Search common ssh config locations under ~/.ssh and merge all Host entries.
Future<List<SshConfigHost>> loadAllSshConfigs() async {
  final out = <SshConfigHost>[];
  try {
    final home = Platform.environment['HOME'];
    if (home == null) return out;
    final candidates = <File>[];
    final primary = File('$home/.ssh/config');
    if (await primary.exists()) candidates.add(primary);

    // ~/.ssh/config.d/*.conf
    final configD = Directory('$home/.ssh/config.d');
    if (await configD.exists()) {
      await for (final e in configD.list()) {
        if (e is File && e.path.endsWith('.conf')) candidates.add(e);
      }
    }
    // ~/.ssh/conf.d/*.conf
    final confD = Directory('$home/.ssh/conf.d');
    if (await confD.exists()) {
      await for (final e in confD.list()) {
        if (e is File && e.path.endsWith('.conf')) candidates.add(e);
      }
    }

    for (final f in candidates) {
      try {
        final content = await f.readAsString();
        out.addAll(SshConfigParser.parse(content));
      } catch (_) {}
    }
  } catch (_) {}
  return out;
}

/// Try to resolve a usable private key path for the given host/user.
/// Priority:
/// 1) ~/.ssh/config (and config.d/conf.d) entries whose Host or HostName matches [host].
///    Return the first IdentityFile if any.
/// 2) Default keys under ~/.ssh: id_ed25519, id_rsa (first existing).
Future<String?> resolvePrivateKeyPath({required String host, String? user}) async {
  try {
    final hosts = await loadAllSshConfigs();
    // Match either alias or HostName
    final cand = hosts.firstWhere(
      (h) => h.host == host || (h.hostName != null && h.hostName == host),
      orElse: () => SshConfigHost(host: ''),
    );
    if (cand.host.isNotEmpty && cand.identityFiles.isNotEmpty) {
      final path = cand.identityFiles.first;
      if (await File(path).exists()) return path;
    }
  } catch (_) {}
  try {
    final home = Platform.environment['HOME'] ?? '';
    if (home.isEmpty) return null;
    final candidates = [
      '$home/.ssh/id_ed25519',
      '$home/.ssh/id_rsa',
    ];
    for (final p in candidates) {
      if (await File(p).exists()) return p;
    }
  } catch (_) {}
  return null;
}
