import 'dart:async';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../models/sync_entry.dart';
import '../services/sync_service.dart';
import '../services/connection_daemon.dart';
import 'remote_browser.dart';
import '../services/ssh_config.dart';
import '../services/sync_status_manager.dart';
import '../utils/time_formatter.dart';

// 添加一个映射来跟踪目录同步状态
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final SyncService _syncService = SyncService();
  final ScrollController _pageScrollCtrl = ScrollController();
  final ConnectionDaemon _connectionDaemon = ConnectionDaemon();
  
  // 添加用于跟踪目录同步状态的映射
  final Map<String, String> _directoryStatus = {};
  late StreamSubscription<List<SyncStatusEvent>> _statusSubscription;

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
  final TextEditingController _excludeRuleCtrl = TextEditingController(); // 添加排除规则输入控制器

  String _status = 'Idle';
  bool _loadingLocal = false;
  bool _loadingRemote = false;
  bool _stackedLayout = false; // true = 一上一下；false = 左右并排（宽屏）
  List<SyncEntry> _localEntries = const [];
  List<SyncEntry> _remoteEntries = const [];
  String? _localError;
  String? _remoteError;

  @override
  void initState() {
    super.initState();
    // 监听同步状态更新
    _statusSubscription = _syncService.statusManager.statusStream.listen((events) {
      // 检查是否有完成的同步操作
      final syncCompleteEvents = events.where((event) => 
        event.operation == SyncOperation.detectChanges && event.isComplete
      );
      
      if (syncCompleteEvents.isNotEmpty) {
        final successEvents = syncCompleteEvents.where((event) => 
          !event.details.contains('失败') && !event.details.contains('错误')
        );
        
        if (successEvents.isNotEmpty) {
          // 同步成功，显示同步时间
          final now = DateTime.now();
          _updateDirectoryStatus(TimeFormatter.formatTimeAgo(now));
        } else {
          // 同步失败
          _updateDirectoryStatus('同步失败');
        }
      }
      
      // 更新状态显示
      if (events.isNotEmpty) {
        setState(() {
          _status = events.first.formattedMessage;
        });
      }
    });
    
    // 初始化时检查目录状态
    _initializeDirectoryStatus();
  }
  
  // 初始化目录状态
  void _initializeDirectoryStatus() {
    // 在下一帧更新UI状态
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final now = DateTime.now();
      _updateDirectoryStatus(TimeFormatter.formatTimeAgo(now));
    });
  }

  @override
  void dispose() {
    _statusSubscription.cancel();
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

  Future<void> _pickRemoteDir() async {
    final host = _remoteHostCtrl.text.trim();
    final user = _remoteUserCtrl.text.trim();
    final pass = _remotePassCtrl.text;
    final port = int.tryParse(_remotePortCtrl.text.trim()) ?? 22;
    if (host.isEmpty || user.isEmpty) {
      _showSnack('请先填写用户名与主机');
      return;
    }
    
    // Register connection with daemon for stability
    _connectionDaemon.registerConnection(
      host: host,
      username: user,
      port: port,
      privateKeyPath: _remoteKeyCtrl.text.trim().isEmpty ? null : _remoteKeyCtrl.text.trim(),
    );
    
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
      // 重置目录状态
      _updateDirectoryStatus('同步中...');
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
      
      // 成功状态将在状态流监听器中更新
      
      await _loadLocalEntries();
      await _loadRemoteEntries();
    } catch (e) {
      if (!mounted) return;
      
      setState(() {
        _status = 'Error: $e';
      });
    }
  }
  
  // 添加方法来更新目录状态显示
  void _updateDirectoryStatus(String statusText) {
    final localPath = _localDirCtrl.text.trim();
    if (localPath.isNotEmpty) {
      setState(() {
        _directoryStatus[localPath] = statusText;
      });
    }
  }
  
  // 获取目录状态显示的辅助方法
  String _getDirectoryStatus(String path) {
    return _directoryStatus[path] ?? '已同步'; // 默认显示已同步
  }

  Future<void> _onStatus() async {
    final out = await _syncService.getStatus();
    if (!mounted) return;
    setState(() {
      _status = out;
    });

    // 显示详细状态信息对话框
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('同步状态'),
        content: SingleChildScrollView(
          child: Text(out),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
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

  Future<void> _onDown() async {
    setState(() {
      _status = '正在暂停会话...';
    });

    try {
      await _syncService.down();
      if (!mounted) return;
      
      setState(() {
        _status = '会话已暂停';
      });
    } catch (e) {
      if (!mounted) return;
      
      setState(() {
        _status = '暂停失败: $e';
      });
    }
  }

  Future<void> _onStop() async {
    setState(() {
      _status = '正在终止会话...';
    });

    try {
      await _syncService.stop();
      if (!mounted) return;
      
      setState(() {
        _status = '会话已终止';
      });
    } catch (e) {
      if (!mounted) return;
      
      setState(() {
        _status = '终止失败: $e';
      });
    }
  }

  Future<void> _onPull() async {
    setState(() {
      _status = '正在从远程拉取...';
      _updateDirectoryStatus('同步中...');
    });

    try {
      _syncService.updateConfig(
        localPath: _localDirCtrl.text.trim(),
        remoteUser: _remoteUserCtrl.text.trim(),
        remoteHost: _remoteHostCtrl.text.trim(),
        remotePath: _remoteDirCtrl.text.trim(),
      );
      await _syncService.pull();
      if (!mounted) return;
      
      setState(() {
        _status = '拉取完成';
      });
      
      await _loadLocalEntries();
      await _loadRemoteEntries();
    } catch (e) {
      if (!mounted) return;
      
      setState(() {
        _status = '拉取失败: $e';
      });
    }
  }

  Future<void> _onPush() async {
    setState(() {
      _status = '正在向远程推送...';
      _updateDirectoryStatus('同步中...');
    });

    try {
      _syncService.updateConfig(
        localPath: _localDirCtrl.text.trim(),
        remoteUser: _remoteUserCtrl.text.trim(),
        remoteHost: _remoteHostCtrl.text.trim(),
        remotePath: _remoteDirCtrl.text.trim(),
      );
      await _syncService.push();
      if (!mounted) return;
      
      setState(() {
        _status = '推送完成';
      });
      
      await _loadLocalEntries();
      await _loadRemoteEntries();
    } catch (e) {
      if (!mounted) return;
      
      setState(() {
        _status = '推送失败: $e';
      });
    }
  }

  Future<void> _onFlush() async {
    setState(() {
      _status = '正在刷新...';
    });

    try {
      await _syncService.flush();
      if (!mounted) return;
      
      setState(() {
        _status = '刷新请求已发送';
      });
    } catch (e) {
      if (!mounted) return;
      
      setState(() {
        _status = '刷新失败: $e';
      });
    }
  }

  // 添加排除规则
  void _addExcludeRule(String rule) {
    if (rule.trim().isEmpty) return;
    
    final newExcludes = List<String>.from(_syncService.config.excludes);
    if (!newExcludes.contains(rule.trim())) {
      newExcludes.add(rule.trim());
      _syncService.updateConfig(excludes: newExcludes);
      _excludeRuleCtrl.clear();
      setState(() {});
    }
  }

  // 删除排除规则
  void _removeExcludeRule(String rule) {
    final newExcludes = List<String>.from(_syncService.config.excludes);
    newExcludes.remove(rule);
    _syncService.updateConfig(excludes: newExcludes);
    setState(() {});
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
                        onPressed: _onDown,
                        icon: const Icon(Icons.pause),
                        label: const Text('Down (pause)'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _onStop,
                        icon: const Icon(Icons.stop),
                        label: const Text('Stop (terminate)'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _onPull,
                        icon: const Icon(Icons.download),
                        label: const Text('Pull (rsync ←)'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _onPush,
                        icon: const Icon(Icons.upload),
                        label: const Text('Push (rsync →)'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _onFlush,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Flush'),
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
                // 添加排除规则管理部分
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '排除规则',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            width: isWide ? 400 : double.infinity,
                            child: TextField(
                              controller: _excludeRuleCtrl,
                              decoration: const InputDecoration(
                                labelText: '添加排除规则',
                                hintText: '例如: *.tmp, build/, .env',
                                suffixIcon: Icon(Icons.add),
                              ),
                              onSubmitted: _addExcludeRule,
                            ),
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                ..._syncService.config.excludes.map((rule) => 
                                  Chip(
                                    label: Text(rule),
                                    deleteIcon: const Icon(Icons.close, size: 18),
                                    onDeleted: () => _removeExcludeRule(rule),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: useRow
                      ? SizedBox(
                          height: constraints.maxHeight - 300, child: content)
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
            TimeFormatter.formatSyncStatus(
              entry.status, 
              entry.modifiedAt, 
              entry.lastSyncAt
            ),
            style: const TextStyle(fontSize: 14),
          ),
        ],
      ),
    );
  }
}

// 将_DirectoryListTile改为public，以便在测试中使用
class DirectoryListTile extends StatelessWidget {
  const DirectoryListTile({required this.entry, super.key});

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
            TimeFormatter.formatSyncStatus(
              entry.status, 
              entry.modifiedAt, 
              entry.lastSyncAt
            ),
            style: const TextStyle(fontSize: 14),
          ),
        ],
      ),
    );
  }
}
















