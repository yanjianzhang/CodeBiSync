import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';
import '../services/sync_service.dart';

class HomePage extends StatefulWidget {
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final SyncService _syncService = SyncService();

  String _status = "Idle";
  final TextEditingController _localDirCtrl = TextEditingController();
  final TextEditingController _remoteDirCtrl = TextEditingController();
  final TextEditingController _remoteUserCtrl = TextEditingController();
  final TextEditingController _remoteHostCtrl = TextEditingController();
  final TextEditingController _sshCmdCtrl = TextEditingController();

  @override
  void dispose() {
    _localDirCtrl.dispose();
    _remoteDirCtrl.dispose();
    _remoteUserCtrl.dispose();
    _remoteHostCtrl.dispose();
    _sshCmdCtrl.dispose();
    super.dispose();
  }

  void _onUp() async {
    setState(() { _status = "Starting up..."; });
    try {
      _syncService.updateConfig(
        localPath: _localDirCtrl.text.trim(),
        remoteUser: _remoteUserCtrl.text.trim(),
        remoteHost: _remoteHostCtrl.text.trim(),
        remotePath: _remoteDirCtrl.text.trim(),
      );
      await _syncService.up();
      setState(() { _status = "Sync session started"; });
    } catch (e) {
      setState(() { _status = "Error: $e"; });
    }
  }

  void _onStatus() async {
    var out = await _syncService.status();
    setState(() { _status = out; });
  }

  Future<void> _pickLocalDir() async {
    final path = await getDirectoryPath();
    if (path != null) {
      _localDirCtrl.text = path;
      _syncService.updateConfig(localPath: path);
      setState(() {});
    }
  }

  void _parseSsh() {
    final m = _syncService.parseSshCommand(_sshCmdCtrl.text);
    if (m.containsKey('user')) _remoteUserCtrl.text = m['user']!;
    if (m.containsKey('host')) _remoteHostCtrl.text = m['host']!;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("CodeBiSync"),
      ),
      body: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Local directory picker
            Text("本地目录", style: Theme.of(context).textTheme.titleMedium),
            SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _localDirCtrl,
                    decoration: InputDecoration(
                      hintText: '选择或输入本地目录路径',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                SizedBox(width: 8),
                ElevatedButton(onPressed: _pickLocalDir, child: Text('选择目录')),
              ],
            ),
            SizedBox(height: 16),

            // Remote settings
            Text("远程设置", style: Theme.of(context).textTheme.titleMedium),
            SizedBox(height: 8),
            TextField(
              controller: _remoteDirCtrl,
              decoration: InputDecoration(
                labelText: '远程目录 (例如: /home/user/project)',
                border: OutlineInputBorder(),
              ),
            ),
            SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _remoteUserCtrl,
                    decoration: InputDecoration(
                      labelText: '用户名',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _remoteHostCtrl,
                    decoration: InputDecoration(
                      labelText: '远端名称 (host)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(height: 16),

            // SSH command parsing
            Text("从 SSH 命令解析", style: Theme.of(context).textTheme.titleMedium),
            SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _sshCmdCtrl,
                    decoration: InputDecoration(
                      hintText: '粘贴 ssh 命令，仅用于解析，不会保存',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                SizedBox(width: 8),
                ElevatedButton(onPressed: _parseSsh, child: Text('解析')),
              ],
            ),

            SizedBox(height: 24),
            Row(
              children: [
                ElevatedButton(onPressed: _onUp, child: Text("Up (start/resume)")),
                SizedBox(width: 8),
                ElevatedButton(onPressed: _onStatus, child: Text("Status")),
              ],
            ),
            SizedBox(height: 16),
            Text("Status:"),
            SizedBox(height: 8),
            Expanded(
              child: SingleChildScrollView(
                child: Text(_status),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
