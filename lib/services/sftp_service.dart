import 'dart:async';

import 'package:dartssh2/dartssh2.dart';

class SftpRemote {
  SSHClient? _client;
  SftpClient? _sftp;

  Future<void> connect({
    required String host,
    required String username,
    String? password,
    String? privateKeyPem,
    String? privateKeyPassphrase,
    int port = 22,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    await disconnect();
    final socket = await SSHSocket.connect(host, port, timeout: timeout);
    final identities = <SSHKeyPair>[];
    if (privateKeyPem != null && privateKeyPem.isNotEmpty) {
      try {
        identities.addAll(SSHKeyPair.fromPem(privateKeyPem, privateKeyPassphrase));
      } catch (_) {
        // fallthrough; connection may still succeed with password
      }
    }
    final client = SSHClient(
      socket,
      username: username,
      identities: identities.isNotEmpty ? identities : null,
      onPasswordRequest: password != null ? () => password : null,
      // Some servers require keyboard-interactive (e.g., PAM/OTP). Use the same
      // password to answer common prompts when provided.
      onUserInfoRequest: (request) {
        if (password == null) return null;
        final answers = <String>[];
        for (final p in request.prompts) {
          final prompt = p.promptText.toLowerCase();
          if (prompt.contains('password') ||
              prompt.contains('verification') ||
              prompt.contains('otp') ||
              prompt.contains('code') ||
              prompt.contains('passcode')) {
            answers.add(password);
          } else {
            answers.add('');
          }
        }
        return answers;
      },
      // In dev it can be slow to verify; leave default behavior (auto-accept if null)
      // disableHostkeyVerification: true,
    );
    _client = client;
    _sftp = await client.sftp();
  }

  bool get isConnected => _sftp != null;

  Future<void> disconnect() async {
    try {
      final s = _sftp;
      if (s != null) s.close();
    } catch (_) {}
    try {
      final c = _client;
      if (c != null) c.close();
    } catch (_) {}
    _sftp = null;
    _client = null;
  }

  Future<List<SftpName>> list(String path) async {
    final s = _sftp;
    if (s == null) return [];
    try {
      final items = await s.listdir(path);
      items.sort((a, b) {
        final aDir = a.attr.isDirectory;
        final bDir = b.attr.isDirectory;
        if (aDir != bDir) return aDir ? -1 : 1;
        return a.filename.toLowerCase().compareTo(b.filename.toLowerCase());
      });
      return items;
    } catch (_) {
      return [];
    }
  }
}
