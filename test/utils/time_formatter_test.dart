import 'package:flutter_test/flutter_test.dart';
import 'package:code_bisync_flutter/utils/time_formatter.dart';
import 'package:code_bisync_flutter/models/sync_entry.dart';

void main() {
  group('TimeFormatter', () {
    group('formatTimeAgo', () {
      test('应该正确格式化秒前的时间', () {
        final now = DateTime.now();
        final dateTime = now.subtract(const Duration(seconds: 30));
        expect(TimeFormatter.formatTimeAgo(dateTime), '30秒前');
      });

      test('应该正确格式化分钟前的时间', () {
        final now = DateTime.now();
        final dateTime = now.subtract(const Duration(minutes: 5));
        expect(TimeFormatter.formatTimeAgo(dateTime), '5分钟前');
      });

      test('应该正确格式化小时前的时间', () {
        final now = DateTime.now();
        final dateTime = now.subtract(const Duration(hours: 2));
        expect(TimeFormatter.formatTimeAgo(dateTime), '2小时前');
      });

      test('应该正确格式化天前的时间', () {
        final now = DateTime.now();
        final dateTime = now.subtract(const Duration(days: 3));
        expect(TimeFormatter.formatTimeAgo(dateTime), '3天前');
      });

      test('应该处理null时间', () {
        expect(TimeFormatter.formatTimeAgo(null), '未知时间');
      });
    });

    group('formatSyncStatus', () {
      test('当修改时间和同步时间相同时应该显示已同步', () {
        final now = DateTime.now();
        final status = TimeFormatter.formatSyncStatus(
          SyncStatus.synced,
          now,
          now,
        );
        expect(status, '已同步');
      });

      test('当状态为synced时应该显示同步时间', () {
        final syncTime = DateTime.now().subtract(const Duration(minutes: 10));
        final status = TimeFormatter.formatSyncStatus(
          SyncStatus.synced,
          DateTime.now(),
          syncTime,
        );
        expect(status, '10分钟前');
      });

      test('当状态为failed时应该显示同步失败', () {
        final status = TimeFormatter.formatSyncStatus(
          SyncStatus.failed,
          DateTime.now(),
          null,
        );
        expect(status, '同步失败');
      });

      test('当状态为pending时应该显示修改时间', () {
        final modifyTime = DateTime.now().subtract(const Duration(seconds: 30));
        final status = TimeFormatter.formatSyncStatus(
          SyncStatus.pending,
          modifyTime,
          null,
        );
        expect(status, '30秒前');
      });

      test('当状态为pending且修改时间为null时应该显示待同步', () {
        final status = TimeFormatter.formatSyncStatus(
          SyncStatus.pending,
          null,
          null,
        );
        expect(status, '待同步');
      });
      
      test('当状态为synced但同步时间为null时应该显示已同步', () {
        final status = TimeFormatter.formatSyncStatus(
          SyncStatus.synced,
          DateTime.now(),
          null,
        );
        expect(status, '已同步');
      });
    });
  });
}