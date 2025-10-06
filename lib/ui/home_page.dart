import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../models/sync_entry.dart';
import '../services/sync_service.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final SyncService _syncService = SyncService();

  final TextEditingController _localDirCtrl = TextEditingController();
  final TextEditingController _remoteDirCtrl = TextEditingController();
  final TextEditingController _remoteUserCtrl = TextEditingController();
  final TextEditingController _remoteHostCtrl = TextEditingController();
  final TextEditingController _sshCmdCtrl = TextEditingController();

  String _status = 'Idle';
  bool _loadingLocal = false;
  bool _loadingRemote = false;
  List<SyncEntry> _localEntries = const [];
  List<SyncEntry> _remoteEntries = const [];
  String? _localError;
  String? _remoteError;

  @override
  void dispose() {
    _localDirCtrl.dispose();
    _remoteDirCtrl.dispose();
    _remoteUserCtrl.dispose();
    _remoteHostCtrl.dispose();
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

    // TODO: Integrate with mutagen session details to fetch real remote metadata.
    try {
      final placeholder = _localEntries.isEmpty
          ? const <SyncEntry>[]
          : _localEntries
              .map((entry) => entry.copyWith(status: entry.status))
              .toList(growable: false);
      if (!mounted) return;
      setState(() {
        _remoteEntries = placeholder;
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

  Future<void> _onCheckEnv() async {
    setState(() {
      _status = '正在检查本地环境...';
    });
    final result = await _syncService.checkEnvironment();
    if (!mounted) return;
    setState(() {
      _status = result;
    });
  }

  Future<void> _onFixPermissions() async {
    setState(() {
      _status = '正在尝试修复 Mutagen 权限...';
    });
    final result = await _syncService.fixPermissions();
    if (!mounted) return;
    setState(() {
      _status = result;
    });
  }

  Future<void> _onOpenTerminalFix() async {
    setState(() {
      _status = '正在打开 Terminal 并填入修复命令...';
    });
    final result = await _syncService.openTerminalForPermissionFix();
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
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth >= 1000;
            final content = isWide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: _DirectoryColumn.local(
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
                      Expanded(child: _DirectoryColumn.remote(
                        remoteHostCtrl: _remoteHostCtrl,
                        remoteUserCtrl: _remoteUserCtrl,
                        remoteDirCtrl: _remoteDirCtrl,
                        entries: _remoteEntries,
                        loading: _loadingRemote,
                        errorText: _remoteError,
                        onRefresh: _loadRemoteEntries,
                        onChanged: ({remotePath, remoteUser, remoteHost}) {
                          _syncService.updateConfig(
                            remotePath: remotePath,
                            remoteUser: remoteUser,
                            remoteHost: remoteHost,
                          );
                        },
                      )),
                    ],
                  )
                : Column(
                    children: [
                      Expanded(child: _DirectoryColumn.local(
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
                      Expanded(child: _DirectoryColumn.remote(
                        remoteHostCtrl: _remoteHostCtrl,
                        remoteUserCtrl: _remoteUserCtrl,
                        remoteDirCtrl: _remoteDirCtrl,
                        entries: _remoteEntries,
                        loading: _loadingRemote,
                        errorText: _remoteError,
                        onRefresh: _loadRemoteEntries,
                        onChanged: ({remotePath, remoteUser, remoteHost}) {
                          _syncService.updateConfig(
                            remotePath: remotePath,
                            remoteUser: remoteUser,
                            remoteHost: remoteHost,
                          );
                        },
                      )),
                    ],
                  );

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
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
                        onPressed: _onCheckEnv,
                        icon: const Icon(Icons.health_and_safety_outlined),
                        label: const Text('检查环境'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _onFixPermissions,
                        icon: const Icon(Icons.build_circle_outlined),
                        label: const Text('修复权限'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _onOpenTerminalFix,
                        icon: const Icon(Icons.code),
                        label: const Text('终端中修复'),
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
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: content,
                  ),
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
    required List<SyncEntry> entries,
    required bool loading,
    required String? errorText,
    required Future<void> Function() onRefresh,
    required void Function({String? remotePath, String? remoteUser, String? remoteHost}) onChanged,
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
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
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
                  color: colorScheme.surfaceVariant.withOpacity(0.35),
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
            if (title == '远程目录')
              Text(
                '远程文件列表暂基于 Mutagen 会话，启动同步后将显示最近一次的状态快照。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
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
    final statusIcon = _statusIcon(entry.status);
    final statusColor = _statusColor(colorScheme, entry.status);
    final modified = _formatDate(entry.modifiedAt);
    final synced = _formatDate(entry.lastSyncAt);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colorScheme.outlineVariant.withOpacity(0.6)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(iconData, color: colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(entry.name, style: Theme.of(context).textTheme.bodyLarge),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      _InfoChip(label: '修改', value: modified),
                      const SizedBox(width: 8),
                      _InfoChip(label: '同步', value: synced),
                    ],
                  ),
                ],
              ),
            ),
            Icon(statusIcon, color: statusColor),
          ],
        ),
      ),
    );
  }

  static IconData _statusIcon(SyncStatus status) {
    switch (status) {
      case SyncStatus.synced:
        return Icons.check_circle;
      case SyncStatus.failed:
        return Icons.cancel;
      case SyncStatus.pending:
      default:
        return Icons.schedule;
    }
  }

  static Color _statusColor(ColorScheme scheme, SyncStatus status) {
    switch (status) {
      case SyncStatus.synced:
        return scheme.primary;
      case SyncStatus.failed:
        return scheme.error;
      case SyncStatus.pending:
      default:
        return scheme.secondary;
    }
  }

  static String _formatDate(DateTime? dateTime) {
    if (dateTime == null) return '--';
    final two = (int v) => v.toString().padLeft(2, '0');
    return '${dateTime.year}-${two(dateTime.month)}-${two(dateTime.day)} ${two(dateTime.hour)}:${two(dateTime.minute)}';
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: colorScheme.surfaceVariant.withOpacity(0.6),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text('$label: $value', style: Theme.of(context).textTheme.bodySmall),
    );
  }
}
