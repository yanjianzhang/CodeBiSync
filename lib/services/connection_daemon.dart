import 'dart:async';
import 'dart:io';

/// A daemon service that maintains stable SSH connections by periodically
/// checking and reconnecting when needed.
class ConnectionDaemon {
  static final ConnectionDaemon _instance = ConnectionDaemon._internal();
  factory ConnectionDaemon() => _instance;
  ConnectionDaemon._internal();

  final Map<String, _ConnectionInfo> _connections = {};
  Timer? _daemonTimer;
  static const Duration _checkInterval = Duration(seconds: 30);
  static const Duration _connectionTimeout = Duration(seconds: 10);

  bool _isRunning = false;

  /// Start the daemon process
  void start() {
    if (_isRunning) return;
    _isRunning = true;
    
    _daemonTimer?.cancel();
    _daemonTimer = Timer.periodic(_checkInterval, (_) => _checkConnections());
  }

  /// Stop the daemon process
  void stop() {
    _isRunning = false;
    _daemonTimer?.cancel();
    _daemonTimer = null;
    _connections.clear();
  }

  /// Register a connection to be monitored by the daemon
  void registerConnection({
    required String host,
    required String username,
    int port = 22,
    String? privateKeyPath,
    String? proxyJump,
    bool compression = false,
    bool forwardAgent = false,
  }) {
    final key = '$username@$host:$port';
    _connections[key] = _ConnectionInfo(
      host: host,
      username: username,
      port: port,
      privateKeyPath: privateKeyPath,
      proxyJump: proxyJump,
      compression: compression,
      forwardAgent: forwardAgent,
      lastChecked: DateTime.now(),
      isConnected: true,
    );
  }

  /// Unregister a connection from daemon monitoring
  void unregisterConnection(String host, String username, int port) {
    final key = '$username@$host:$port';
    _connections.remove(key);
  }

  /// Check all registered connections and reconnect if needed
  Future<void> _checkConnections() async {
    if (!_isRunning) return;

    final now = DateTime.now();
    final connectionsToCheck = _connections.entries
        .where((entry) => now.difference(entry.value.lastChecked) > _checkInterval)
        .toList();

    for (final entry in connectionsToCheck) {
      final key = entry.key;
      final info = entry.value;
      
      try {
        // Perform a lightweight connectivity check
        await _testConnection(info);
        info.isConnected = true;
        info.lastChecked = now;
      } catch (e) {
        // Mark connection as disconnected but keep it registered
        info.isConnected = false;
        info.lastChecked = now;
        // Log the error but don't rethrow to prevent breaking the daemon
        stderr.writeln('Connection daemon: Failed to connect to ${info.host}: $e');
      }
    }
  }

  /// Test connection with a lightweight SSH command
  Future<void> _testConnection(_ConnectionInfo info) async {
    try {
      final args = <String>[
        '-p', info.port.toString(),
        '-o', 'ConnectTimeout=${_connectionTimeout.inSeconds}',
        '-o', 'BatchMode=yes',
        '-o', 'StrictHostKeyChecking=no',
        '-o', 'UserKnownHostsFile=/dev/null',
        if (info.compression) '-C',
        if (info.forwardAgent) '-A',
        if (info.proxyJump != null && info.proxyJump!.isNotEmpty) ...['-J', info.proxyJump!],
        if (info.privateKeyPath != null && info.privateKeyPath!.isNotEmpty) ...['-i', info.privateKeyPath!],
        '${info.username.isNotEmpty ? '${info.username}@' : ''}${info.host}', 
        'echo', 'ping'
      ];

      final process = await Process.run('ssh', args, runInShell: false);
      if (process.exitCode != 0) {
        throw Exception('SSH connectivity test failed: ${process.stderr}');
      }
    } catch (e) {
      rethrow;
    }
  }

  /// Get connection status
  bool isConnectionStable(String host, String username, int port) {
    final key = '$username@$host:$port';
    final info = _connections[key];
    return info?.isConnected ?? false;
  }
}

class _ConnectionInfo {
  String host;
  String username;
  int port;
  String? privateKeyPath;
  String? proxyJump;
  bool compression;
  bool forwardAgent;
  DateTime lastChecked;
  bool isConnected;

  _ConnectionInfo({
    required this.host,
    required this.username,
    required this.port,
    this.privateKeyPath,
    this.proxyJump,
    required this.compression,
    required this.forwardAgent,
    required this.lastChecked,
    required this.isConnected,
  });
}