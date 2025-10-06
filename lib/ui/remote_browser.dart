import '../services/ssh_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/rsync_service.dart';

class RemoteBrowserDialog extends StatefulWidget {
  final String host;
  final String username;
  final String? password;
  final int port;
  final String initialPath;
  final String? privateKeyPath;
  final String? privateKeyPassphrase;

  const RemoteBrowserDialog({
    super.key,
    required this.host,
    required this.username,
    this.password,
    this.port = 22,
    this.initialPath = '/',
    this.privateKeyPath,
    this.privateKeyPassphrase,
  });

  static Future<String?> pick({
    required BuildContext context,
    required String host,
    required String username,
    String? password,
    int port = 22,
    String initialPath = '/',
    String? privateKeyPath,
    String? privateKeyPassphrase,
  }) async {
    return await showDialog<String>(
      context: context,
      barrierDismissible: true,
      builder: (_) => Dialog(
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: SizedBox(
          width: 720,
          height: 520,
          // Use a unique key to force a fresh state each time, ensuring reconnection
          child: RemoteBrowserDialog(
            key: UniqueKey(),
            host: host,
            username: username,
            password: password,
            port: port,
            initialPath: initialPath,
            privateKeyPath: privateKeyPath,
            privateKeyPassphrase: privateKeyPassphrase,
          ),
        ),
      ),
    );
  }

  @override
  State<RemoteBrowserDialog> createState() => _RemoteBrowserDialogState();
}

class _RemoteBrowserDialogState extends State<RemoteBrowserDialog> {
  String _cwd = '/';
  bool _loading = false;
  String? _error;
  List<RsyncEntry> _entries = const [];
  String? _resolvedKeyPath;
  String? _proxyJump;
  bool _compression = false;
  bool _forwardAgent = false;
  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _cwd = widget.initialPath.isNotEmpty ? widget.initialPath : '/';
    _connectAndList();
  }

  Future<void> _connectAndList() async {
    setState(() { _loading = true; _error = null; });
    try {
      // Resolve ssh options from config if available
      final hosts = await loadAllSshConfigs();
      final matched = hosts.firstWhere(
        (h) => h.host == widget.host || h.hostName == widget.host,
        orElse: () => SshConfigHost(host: ''),
      );
      if (matched.host.isNotEmpty) {
        _proxyJump = matched.proxyJump;
        _compression = matched.compression;
        _forwardAgent = matched.forwardAgent;
      }

      String? keyPath = widget.privateKeyPath;
      // Auto-resolve private key from ssh config or defaults when not provided
      if (keyPath == null || keyPath.isEmpty) {
        keyPath = await resolvePrivateKeyPath(host: widget.host, user: widget.username);
      }
      _resolvedKeyPath = keyPath;
      await _list(_cwd);
    } catch (e) {
      setState(() { _error = '连接失败: $e'; _entries = const []; });
    } finally {
      setState(() { _loading = false; });
    }
  }

  Future<void> _list(String path) async {
    setState(() { _loading = true; _error = null; });
    try {
      final items = await RsyncService.list(
        host: widget.host,
        username: widget.username,
        path: path,
        port: widget.port,
        identityFile: _resolvedKeyPath,
        proxyJump: _proxyJump,
        compression: _compression,
        forwardAgent: _forwardAgent,
        dirsOnly: true,
      );
      setState(() { _cwd = path; _entries = items; });
    } catch (e) {
      setState(() { _error = '读取目录失败: $e'; _entries = const []; });
    } finally {
      setState(() { _loading = false; });
    }
  }

  void _pick() {
    Navigator.of(context).pop(_cwd);
  }

  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          color: Theme.of(context).colorScheme.surfaceVariant,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _cwd,
                  style: Theme.of(context).textTheme.bodyMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: '复制 rsync 命令到剪贴板',
                child: IconButton(
                  icon: const Icon(Icons.copy_all_outlined),
                  onPressed: () async {
                    final cmd = _buildRsyncCommand(_cwd);
                    await Clipboard.setData(ClipboardData(text: cmd));
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('已复制 rsync 命令')),
                      );
                    }
                  },
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: TextField(
            controller: _searchCtrl,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: '输入关键字筛选当前结果（回车清空）',
            ),
            onSubmitted: (_) => setState(() {}),
            onChanged: (_) => setState(() {}),
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(child: Text(_error!))
                  : ListView.builder(
                      itemCount: _filteredEntries.length + (_cwd != '/' ? 1 : 0),
                      itemBuilder: (context, index) {
                        if (_cwd != '/' && index == 0) {
                          return ListTile(
                            leading: const Icon(Icons.arrow_upward),
                            title: const Text('..'),
                            onTap: () {
                              final parent = _parent(_cwd);
                              _list(parent);
                            },
                          );
                        }
                        final i = _cwd != '/' ? index - 1 : index;
                        final e = _filteredEntries[i];
                        final isDir = e.isDirectory;
                        return ListTile(
                          leading: Icon(isDir ? Icons.folder : Icons.description),
                          title: Text(e.name),
                          onTap: isDir ? () => _list(_join(_cwd, e.name)) : null,
                          onLongPress: isDir ? null : null,
                        );
                      },
                    ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              OutlinedButton(onPressed: () => Navigator.of(context).maybePop(), child: const Text('取消')),
              const Spacer(),
              FilledButton(onPressed: _pick, child: const Text('选择此目录')),
            ],
          ),
        )
      ],
    );
  }

  static String _parent(String path) {
    if (path == '/' || path.isEmpty) return '/';
    final t = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
    final idx = t.lastIndexOf('/');
    if (idx <= 0) return '/';
    return t.substring(0, idx);
  }

  static String _join(String a, String b) {
    if (a.endsWith('/')) return a + b;
    return a + '/' + b;
  }

  String _buildRsyncCommand(String path) {
    final normalized = path.isEmpty ? '/' : (path.endsWith('/') ? path : '$path/');
    final sshArgs = <String>[
      'ssh',
      '-p', '${widget.port}',
      '-o', 'StrictHostKeyChecking=no',
      '-o', 'UserKnownHostsFile=/dev/null',
      '-o', 'BatchMode=yes',
      if (_compression) '-C',
      if (_forwardAgent) '-A',
      if (_proxyJump != null && _proxyJump!.isNotEmpty) ...['-J', _proxyJump!],
      if (_resolvedKeyPath != null && _resolvedKeyPath!.isNotEmpty) ...['-i', _resolvedKeyPath!],
    ];
    final sshPart = '"' + sshArgs.join(' ') + '"';
    final userAtHost = (widget.username.isNotEmpty ? '${widget.username}@' : '') + widget.host;
    final remote = userAtHost + ':' + '"' + normalized.replaceAll('"', '\\"') + '"';
    // Use immediate-only listing to keep it fast, same as UI
    return 'rsync -av --list-only --exclude "*/**" -e ' + sshPart + ' ' + remote;
  }

  List<RsyncEntry> get _filteredEntries {
    final q = _searchCtrl.text.trim().toLowerCase();
    if (q.isEmpty) return _entries;
    return _entries.where((e) => e.name.toLowerCase().contains(q)).toList();
  }
}
