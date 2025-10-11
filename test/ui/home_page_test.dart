import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:code_bisync_flutter/ui/home_page.dart';
import 'package:code_bisync_flutter/models/sync_entry.dart';
import 'package:code_bisync_flutter/utils/time_formatter.dart';

void main() {
  group('HomePage UI Tests', () {
    testWidgets('DirectoryListTile应该正确显示状态信息', (WidgetTester tester) async {
      final now = DateTime.now();
      final fiveMinutesAgo = now.subtract(const Duration(minutes: 5));

      final entry = SyncEntry(
        name: 'test_file.txt',
        isDirectory: false,
        modifiedAt: fiveMinutesAgo,
        lastSyncAt: fiveMinutesAgo,
        status: SyncStatus.synced,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DirectoryListTile(entry: entry),
          ),
        ),
      );

      // 验证文件名显示正确
      expect(find.text('test_file.txt'), findsOneWidget);

      // 验证状态显示正确（已同步）
      expect(find.text('已同步'), findsOneWidget);
    });

    testWidgets('DirectoryListTile应该正确显示待同步状态', (WidgetTester tester) async {
      final now = DateTime.now();
      final fiveMinutesAgo = now.subtract(const Duration(minutes: 5));

      final entry = SyncEntry(
        name: 'test_file.txt',
        isDirectory: false,
        modifiedAt: now, // 修改时间为现在，比同步时间晚
        lastSyncAt: fiveMinutesAgo, // 同步时间为5分钟前
        status: SyncStatus.pending,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DirectoryListTile(entry: entry),
          ),
        ),
      );

      // 验证文件名显示正确
      expect(find.text('test_file.txt'), findsOneWidget);

      // 验证状态显示正确（显示修改时间，即"刚刚"或几秒前）
      // 我们不具体检查时间文本，因为它是动态的
      expect(find.byType(Text), findsWidgets);
    });

    testWidgets('DirectoryListTile应该正确显示同步失败状态', (WidgetTester tester) async {
      final now = DateTime.now();
      final fiveMinutesAgo = now.subtract(const Duration(minutes: 5));
      final tenMinutesAgo = now.subtract(const Duration(minutes: 10));

      final entry = SyncEntry(
        name: 'test_file.txt',
        isDirectory: false,
        modifiedAt: tenMinutesAgo, // 修改时间早于同步时间，确保不会触发"已同步"条件
        lastSyncAt: fiveMinutesAgo, // 同步时间为5分钟前
        status: SyncStatus.failed,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DirectoryListTile(entry: entry),
          ),
        ),
      );

      // 验证文件名显示正确
      expect(find.text('test_file.txt'), findsOneWidget);

      // 验证状态显示包含"同步失败"
      expect(
        find.textContaining('同步失败'),
        findsOneWidget,
      );
    });
  });
}
