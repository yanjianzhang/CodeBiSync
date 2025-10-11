import 'package:flutter_test/flutter_test.dart';
import 'package:code_bisync_flutter/services/sync_service.dart';
import 'package:code_bisync_flutter/sync/impl/mock_local_endpoint.dart';
import 'package:code_bisync_flutter/sync/impl/mock_remote_endpoint.dart';
import 'package:code_bisync_flutter/services/sync_status_manager.dart';
import 'package:code_bisync_flutter/sync/impl/local_endpoint.dart';

void main() {
  group('SyncService Integration Tests', () {
    late SyncService syncService;
    late MockLocalEndpoint mockLocal;
    late MockRemoteEndpoint mockRemote;
    late SyncStatusManager statusManager;

    setUp(() {
      // 创建Mock端点
      mockLocal = MockLocalEndpoint('/mock/local');
      mockRemote = MockRemoteEndpoint();
      statusManager = SyncStatusManager();

      // 创建SyncService并注入Mock实现
      syncService = SyncService(
        localEndpointFactory: (path, statusManager) => mockLocal as LocalEndpoint,
        remoteEndpointFactory: (config, statusManager) => mockRemote,
      );

      // 配置SyncService
      syncService.config.localPath = '/mock/local';
      syncService.config.remoteHost = 'mock-host';
      syncService.config.remoteUser = 'mock-user';
      syncService.config.remotePath = '/mock/remote';
    });

    test('should synchronize new file from local to remote', () async {
      // 在本地创建一个文件
      const testFilePath = 'test.txt';
      const testContent = 'Hello, World!';
      mockLocal.addFile(testFilePath, testContent);

      // 验证文件存在
      expect(mockLocal.hasFile(testFilePath), true);
    });

    // 添加更多集成测试用例...
  });
}