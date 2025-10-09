import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../models/sync_entry.dart';
import '../services/sync_service.dart';
import 'remote_browser.dart';
import '../services/ssh_config.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final SyncService _syncService = SyncService();
  final ScrollController _pageScrollCtrl = ScrollController();

  final TextEditingController _localDirCtrl = TextEditingController();
  final TextEditingController _remoteDirCtrl = TextEditingController();
  final TextEditingController _remoteUserCtrl = TextEditingController();
  final TextEditingController _remoteHostCtrl = TextEditingController();
  final TextEditingController _remotePortCtrl =
      TextEditingController(text: '22');
  final TextEditingController _remotePassCtrl = TextEditingController();
  final TextEditingController _remoteKeyCtrl = TextEditingController();
  final TextEditingController _remoteKeyPassCtrl = TextEditingController();
  final TextEditingController _sshCmdCtrl = TextEditingController();

  String _status = 'Idle';
  bool _loadingLocal = false;
  bool _loadingRemote = false;
  bool _stackedLayout = false; // true = 一上一下；false = 左右并排（宽屏）
  List<SyncEntry> _localEntries = const [];
  List<SyncEntry> _remoteEntries = const [];
  String? _localError;
  String? _remoteError;

  Future<void> _pickRemoteDir() async {
    final host = _remoteHostCtrl.text.trim();
    final user = _remoteUserCtrl.text.trim();
    final pass = _remotePassCtrl.text;
    final port = int.tryParse(_remotePortCtrl.text.trim()) ?? 22;
    if (host.isEmpty || user.isEmpty) {
      _showSnack('请先填写用户名与主机');
      return;
    }
    final picked = await RemoteBrowserDialog.pick(
      context: context,
      host: host,
      username: user,
      password: pass,
      port: port,
      initialPath:
          _remoteDirCtrl.text.trim().isEmpty ? '/' : _remoteDirCtrl.text.trim(),
      privateKeyPath: _remoteKeyCtrl.text.trim().isEmpty
          ? null
          : _remoteKeyCtrl.text.trim(),
      privateKeyPassphrase: _remoteKeyPassCtrl.text,
    );
    if (picked != null && picked.isNotEmpty) {
      _remoteDirCtrl.text = picked;
      _syncService.updateConfig(remotePath: picked);
      await _loadRemoteEntries();
    }
  }

  @override
  void dispose() {
    _localDirCtrl.dispose();
    _remoteDirCtrl.dispose();
    _remoteUserCtrl.dispose();
    _remoteHostCtrl.dispose();
    _remotePortCtrl.dispose();
    _remotePassCtrl.dispose();
    _remoteKeyCtrl.dispose();
    _remoteKeyPassCtrl.dispose();
    _sshCmdCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickLocalDir() async {
    try {
      final path = await getDirectoryPath();
      if (path == null) return;

      _localDirCtrl.text = path;
      _syncService.updateConfig(localPath: path);
      await _loadLocalEntries();
    } catch (e) {
      _showSnack('无法打开目录选择器: $e');
    }
  }

  Future<void> _loadLocalEntries() async {
    final path = _localDirCtrl.text.trim();
    if (path.isEmpty) {
      setState(() {
        _localEntries = const [];
        _localError = '请选择本地目录';
      });
      return;
    }

    setState(() {
      _loadingLocal = true;
      _localError = null;
    });

    try {
      final entries = await _syncService.listLocalEntries(path);
      if (!mounted) return;
      setState(() {
        _localEntries = entries;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _localError = '无法读取目录：$e';
        _localEntries = const [];
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _loadingLocal = false;
      });
    }
  }

  Future<void> _loadRemoteEntries() async {
    final remotePath = _remoteDirCtrl.text.trim();
    final remoteUser = _remoteUserCtrl.text.trim();
    final remoteHost = _remoteHostCtrl.text.trim();

    if (remotePath.isEmpty || remoteUser.isEmpty || remoteHost.isEmpty) {
      setState(() {
        _remoteEntries = const [];
        _remoteError = '请填写完整的远程连接信息';
      });
      return;
    }

    setState(() {
      _loadingRemote = true;
      _remoteError = null;
    });

    try {
      final entries = await _syncService.listRemoteEntries();
      if (!mounted) return;
      setState(() {
        _remoteEntries = entries;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _remoteError = '远程信息暂不可用：$e';
        _remoteEntries = const [];
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _loadingRemote = false;
      });
    }
  }

  Future<void> _resolvePrivateKey() async {
    final host = _remoteHostCtrl.text.trim();
    final user = _remoteUserCtrl.text.trim();
    if (host.isEmpty) {
      _showSnack('请先填写主机名');
      return;
    }
    final path = await resolvePrivateKeyPath(
        host: host, user: user.isEmpty ? null : user);
    if (path != null) {
      _remoteKeyCtrl.text = path;
      setState(() {});
      _showSnack('已找到私钥: $path');
    } else {
      _showSnack('未在 ~/.ssh 下找到可用私钥');
    }
  }

  void _parseSsh() {
    final mapping = _syncService.parseSshCommand(_sshCmdCtrl.text);
    if (mapping.containsKey('user')) {
      _remoteUserCtrl.text = mapping['user']!;
      _syncService.updateConfig(remoteUser: mapping['user']);
    }
    if (mapping.containsKey('host')) {
      _remoteHostCtrl.text = mapping['host']!;
      _syncService.updateConfig(remoteHost: mapping['host']);
    }
    setState(() {});
  }

  Future<void> _onUp() async {
    setState(() {
      _status = 'Starting up...';
    });

    try {
      _syncService.updateConfig(
        localPath: _localDirCtrl.text.trim(),
        remoteUser: _remoteUserCtrl.text.trim(),
        remoteHost: _remoteHostCtrl.text.trim(),
        remotePath: _remoteDirCtrl.text.trim(),
      );
      await _syncService.up();
      if (!mounted) return;
      setState(() {
        _status = 'Sync session started';
      });
      await _loadLocalEntries();
      await _loadRemoteEntries();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = 'Error: $e';
      });
    }
  }

  Future<void> _onStatus() async {
    final out = await _syncService.status();
    if (!mounted) return;
    setState(() {
      _status = out;
    });
  }

  Future<void> _onDiagnose() async {
    setState(() {
      _status = '正在诊断同步...';
    });
    final result = await _syncService.diagnoseLocalSync();
    if (!mounted) return;
    setState(() {
      _status = result;
    });
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('CodeBiSync'),
        centerTitle: true,
        actions: [
          Tooltip(
            message: _stackedLayout ? '切换为左右布局' : '切换为上下布局',
            child: IconButton(
              icon: Icon(_stackedLayout ? Icons.view_week : Icons.view_agenda),
              onPressed: () => setState(() => _stackedLayout = !_stackedLayout),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth >= 1000;
            final useRow = !_stackedLayout && isWide;
            final content = useRow
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                          flex: 1,
                          child: _DirectoryColumn.local(
                            controller: _localDirCtrl,
                            entries: _localEntries,
                            loading: _loadingLocal,
                            errorText: _localError,
                            onRefresh: _loadLocalEntries,
                            onPickDirectory: _pickLocalDir,
                            onChanged: (value) {
                              _syncService.updateConfig(localPath: value);
                            },
                          )),
                      const SizedBox(width: 24),
                      Expanded(
                          flex: 2,
                          child: _DirectoryColumn.remote(
                            remoteHostCtrl: _remoteHostCtrl,
                            remoteUserCtrl: _remoteUserCtrl,
                            remoteDirCtrl: _remoteDirCtrl,
                            remotePortCtrl: _remotePortCtrl,
                            remotePassCtrl: _remotePassCtrl,
                            remoteKeyCtrl: _remoteKeyCtrl,
                            remoteKeyPassCtrl: _remoteKeyPassCtrl,
                            entries: _remoteEntries,
                            loading: _loadingRemote,
                            errorText: _remoteError,
                            onRefresh: _loadRemoteEntries,
                            onPickRemoteDir: _pickRemoteDir,
                            onPickPrivateKey: _resolvePrivateKey,
                            onChanged: (
                                {remotePath,
                                remoteUser,
                                remoteHost,
                                port,
                                password,
                                keyPath,
                                keyPass}) {
                              _syncService.updateConfig(
                                remotePath: remotePath,
                                remoteUser: remoteUser,
                                remoteHost: remoteHost,
                                remotePort: port,
                                identityFile: keyPath,
                              );
                            },
                          )),
                    ],
                  )
                : Column(
                    children: [
                      SizedBox(
                          height: 300,
                          child: _DirectoryColumn.local(
                            controller: _localDirCtrl,
                            entries: _localEntries,
                            loading: _loadingLocal,
                            errorText: _localError,
                            onRefresh: _loadLocalEntries,
                            onPickDirectory: _pickLocalDir,
                            onChanged: (value) {
                              _syncService.updateConfig(localPath: value);
                            },
                          )),
                      const SizedBox(height: 24),
                      SizedBox(
                          height: 560,
                          child: _DirectoryColumn.remote(
                            remoteHostCtrl: _remoteHostCtrl,
                            remoteUserCtrl: _remoteUserCtrl,
                            remoteDirCtrl: _remoteDirCtrl,
                            remotePortCtrl: _remotePortCtrl,
                            remotePassCtrl: _remotePassCtrl,
                            remoteKeyCtrl: _remoteKeyCtrl,
                            remoteKeyPassCtrl: _remoteKeyPassCtrl,
                            entries: _remoteEntries,
                            loading: _loadingRemote,
                            errorText: _remoteError,
                            onRefresh: _loadRemoteEntries,
                            onPickRemoteDir: _pickRemoteDir,
                            onPickPrivateKey: _resolvePrivateKey,
                            onChanged: (
                                {remotePath,
                                remoteUser,
                                remoteHost,
                                port,
                                password,
                                keyPath,
                                keyPass}) {
                              _syncService.updateConfig(
                                remotePath: remotePath,
                                remoteUser: remoteUser,
                                remoteHost: remoteHost,
                                remotePort: port,
                                identityFile: keyPath,
                              );
                            },
                          )),
                    ],
                  );

            final page = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                  child: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      FilledButton.icon(
                        onPressed: _onUp,
                        icon: const Icon(Icons.cloud_sync),
                        label: const Text('Up (start/resume)'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _onStatus,
                        icon: const Icon(Icons.info_outline),
                        label: const Text('Status'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _onDiagnose,
                        icon: const Icon(Icons.health_and_safety_outlined),
                        label: const Text('诊断同步'),
                      ),
                      SizedBox(
                        width: isWide ? 320 : double.infinity,
                        child: TextField(
                          controller: _sshCmdCtrl,
                          decoration: InputDecoration(
                            labelText: '从 SSH 命令解析',
                            hintText: 'ssh user@host ...',
                            suffixIcon: IconButton(
                              tooltip: '解析',
                              onPressed: _parseSsh,
                              icon: const Icon(Icons.auto_fix_high),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: useRow
                      ? SizedBox(
                          height: constraints.maxHeight - 210, child: content)
                      : content,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: SelectableText(
                        _status,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                  ),
                ),
              ],
            );

            return Scrollbar(
              controller: _pageScrollCtrl,
              thumbVisibility: true,
              child: SingleChildScrollView(
                controller: _pageScrollCtrl,
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: page,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _DirectoryColumn extends StatelessWidget {
  const _DirectoryColumn._({
    required this.title,
    required this.header,
    required this.entries,
    required this.loading,
    required this.errorText,
    required this.onRefresh,
  });

  factory _DirectoryColumn.local({
    required TextEditingController controller,
    required List<SyncEntry> entries,
    required bool loading,
    required String? errorText,
    required Future<void> Function() onRefresh,
    required Future<void> Function() onPickDirectory,
    required void Function(String value) onChanged,
  }) {
    return _DirectoryColumn._(
      title: '本地目录',
      header: (context) => Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              decoration: const InputDecoration(
                labelText: '选择或输入本地目录路径',
              ),
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.tonalIcon(
            onPressed: onPickDirectory,
            icon: const Icon(Icons.folder_open),
            label: const Text('选择目录'),
          ),
        ],
      ),
      entries: entries,
      loading: loading,
      errorText: errorText,
      onRefresh: onRefresh,
    );
  }

  factory _DirectoryColumn.remote({
    required TextEditingController remoteHostCtrl,
    required TextEditingController remoteUserCtrl,
    required TextEditingController remoteDirCtrl,
    TextEditingController? remotePortCtrl,
    TextEditingController? remotePassCtrl,
    TextEditingController? remoteKeyCtrl,
    TextEditingController? remoteKeyPassCtrl,
    required List<SyncEntry> entries,
    required bool loading,
    required String? errorText,
    required Future<void> Function() onRefresh,
    required void Function(
            {String? remotePath,
            String? remoteUser,
            String? remoteHost,
            int? port,
            String? password,
            String? keyPath,
            String? keyPass})
        onChanged,
    Future<void> Function()? onPickRemoteDir,
    Future<void> Function()? onPickPrivateKey,
  }) {
    return _DirectoryColumn._(
      title: '远程目录',
      header: (context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: remoteDirCtrl,
                  onChanged: (value) => onChanged(remotePath: value),
                  decoration: const InputDecoration(
                    labelText: '远程目录 (例如: /home/user/project)',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              if (onPickRemoteDir != null)
                FilledButton.tonalIcon(
                  onPressed: onPickRemoteDir,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('选择目录'),
                ),
              const SizedBox(width: 12),
              FilledButton.tonalIcon(
                onPressed: () async {
                  // 先尝试自动搜索 ~/.ssh 下的常见位置
                  var hosts = await loadAllSshConfigs();
                  if (!context.mounted) return;
                  if (hosts.isEmpty) {
                    // 可能是沙盒导致读取失败；提示并让用户选择 ~/.ssh/config 以授权访问
                    final proceed = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('需要授权读取 ~/.ssh/config'),
                        content: const Text(
                            '由于 macOS 沙盒限制，应用需要您选择一次 SSH 配置文件以授予访问权限。'),
                        actions: [
                          TextButton(
                              onPressed: () => Navigator.of(ctx).pop(false),
                              child: const Text('取消')),
                          FilledButton(
                              onPressed: () => Navigator.of(ctx).pop(true),
                              child: const Text('选择文件')),
                        ],
                      ),
                    );
                    if (proceed != true || !context.mounted) return;

                    try {
                      const typeGroup = XTypeGroup(
                          label: 'ssh-config', extensions: ['config']);
                      final picked =
                          await openFile(acceptedTypeGroups: [typeGroup]);
                      if (picked != null) {
                        final content = await picked.readAsString();
                        hosts = SshConfigParser.parse(content);
                      }
                    } catch (_) {}
                  }
                  if (hosts.isEmpty || !context.mounted) return;
                  // Show simple picker
                  final selected = await showDialog<SshConfigHost>(
                    context: context,
                    builder: (ctx) => SimpleDialog(
                      title: const Text('选择 SSH Host'),
                      children: [
                        SizedBox(
                          width: 480,
                          height: 360,
                          child: ListView.builder(
                            itemCount: hosts.length,
                            itemBuilder: (c, i) {
                              final h = hosts[i];
                              final subtitle = [
                                if (h.user != null) 'user: ${h.user}',
                                if (h.hostName != null) 'host: ${h.hostName}',
                                if (h.port != null) 'port: ${h.port}',
                                if (h.identityFiles.isNotEmpty)
                                  'key: ${h.identityFiles.first}',
                              ].join('  ·  ');
                              return ListTile(
                                title: Text(h.host),
                                subtitle: Text(subtitle),
                                onTap: () => Navigator.of(ctx).pop(h),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  );
                  if (!context.mounted || selected == null) return;
                  remoteUserCtrl.text = selected.user ?? remoteUserCtrl.text;
                  remoteHostCtrl.text = selected.hostName ?? selected.host;
                  remotePortCtrl?.text = (selected.port ?? 22).toString();
                  // 自动解析私钥：优先 IdentityFile；否则从默认路径推断
                  String? keyPath;
                  if (selected.identityFiles.isNotEmpty) {
                    keyPath = selected.identityFiles.first;
                  } else {
                    keyPath = await resolvePrivateKeyPath(
                      host: selected.hostName ?? selected.host,
                      user: selected.user,
                    );
                  }
                  if (keyPath != null && remoteKeyCtrl != null) {
                    remoteKeyCtrl.text = keyPath;
                  }
                  onChanged(
                    remoteUser: selected.user,
                    remoteHost: selected.hostName ?? selected.host,
                    port: selected.port,
                    keyPath: keyPath,
                  );
                  if (context.mounted) {
                    // 移除 setState 调用，因为我们已经通过 onChanged 通知了更改
                    // setState(() {});
                  }
                },
                icon: const Icon(Icons.input),
                label: const Text('从 SSH 配置导入'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: remoteUserCtrl,
                  onChanged: (value) => onChanged(remoteUser: value),
                  decoration: const InputDecoration(labelText: '用户名'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: remoteHostCtrl,
                  onChanged: (value) => onChanged(remoteHost: value),
                  decoration: const InputDecoration(labelText: '远端名称 (host)'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: remotePortCtrl,
                  keyboardType: TextInputType.number,
                  onChanged: (value) => onChanged(port: int.tryParse(value)),
                  decoration: const InputDecoration(labelText: '端口 (默认 22)'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: remotePassCtrl,
                  obscureText: true,
                  onChanged: (value) => onChanged(password: value),
                  decoration: const InputDecoration(labelText: '密码（使用私钥可留空）'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: remoteKeyCtrl,
                  onChanged: (value) => onChanged(keyPath: value),
                  decoration: const InputDecoration(labelText: '私钥文件路径 (PEM)'),
                ),
              ),
              const SizedBox(width: 12),
              if (onPickPrivateKey != null)
                FilledButton.tonalIcon(
                  onPressed: onPickPrivateKey,
                  icon: const Icon(Icons.vpn_key),
                  label: const Text('搜索私钥'),
                ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: remoteKeyPassCtrl,
            obscureText: true,
            onChanged: (value) => onChanged(keyPass: value),
            decoration: const InputDecoration(labelText: '私钥 Passphrase（如果有）'),
          ),
        ],
      ),
      entries: entries,
      loading: loading,
      errorText: errorText,
      onRefresh: onRefresh,
    );
  }

  final String title;
  final Widget Function(BuildContext context) header;
  final List<SyncEntry> entries;
  final bool loading;
  final String? errorText;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.storage_rounded, color: colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                IconButton(
                  tooltip: '刷新',
                  onPressed: onRefresh,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            const SizedBox(height: 18),
            header(context),
            const SizedBox(height: 24),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest
                      .withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: _DirectoryListView(
                  entries: entries,
                  loading: loading,
                  errorText: errorText,
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

class _DirectoryListView extends StatelessWidget {
  const _DirectoryListView({
    required this.entries,
    required this.loading,
    required this.errorText,
  });

  final List<SyncEntry> entries;
  final bool loading;
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (errorText != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(errorText!, textAlign: TextAlign.center),
        ),
      );
    }

    if (entries.isEmpty) {
      return Center(
        child: Text(
          '暂无数据',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      );
    }

    return ListView.separated(
      itemCount: entries.length,
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
      itemBuilder: (context, index) {
        final entry = entries[index];
        return _DirectoryListTile(entry: entry);
      },
      separatorBuilder: (_, __) => const SizedBox(height: 8),
    );
  }
}

class _DirectoryListTile extends StatelessWidget {
  const _DirectoryListTile({required this.entry});

  final SyncEntry entry;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final iconData = entry.isDirectory ? Icons.folder : Icons.description;

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: colorScheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Icon(iconData, size: 18, color: colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              entry.name,
              style: Theme.of(context).textTheme.bodyMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _glyph(entry.status),
            style: const TextStyle(fontSize: 16),
          ),
        ],
      ),
    );
  }

  String _glyph(SyncStatus status) {
    switch (status) {
      case SyncStatus.synced:
        return '✅';
      case SyncStatus.failed:
        return '❌';
      case SyncStatus.pending:
      default:
        return '🕙';
    }
  }
}
