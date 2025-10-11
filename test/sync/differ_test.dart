import 'package:flutter_test/flutter_test.dart';
import 'package:code_bisync_flutter/sync/impl/simple_differ.dart';
import 'package:code_bisync_flutter/sync/snapshot.dart';
import 'package:code_bisync_flutter/sync/differ_models.dart';

void main() {
  group('SimpleDiffer', () {
    late SimpleDiffer differ;

    setUp(() {
      differ = SimpleDiffer();
    });

    test('should detect creation on alpha side', () {
      // 基线为空
      final base = Snapshot({});

      // Alpha有一个新文件
      final alphaEntries = {
        'test.txt': FileMetadata(
          path: 'test.txt',
          isDirectory: false,
          size: 10,
          mtime: DateTime(2023, 1, 1),
        ),
      };
      final alpha = Snapshot(alphaEntries);

      // Beta为空
      final beta = Snapshot({});

      // 执行差异比较
      final plan = differ.reconcile(base, alpha, beta);

      // 验证结果：应将文件从alpha复制到beta
      expect(plan.alphaToBeta.length, 1);
      expect(plan.alphaToBeta[0].path, 'test.txt');
      expect(plan.alphaToBeta[0].type, ChangeType.create);
      expect(plan.betaToAlpha.isEmpty, true);
      expect(plan.conflicts.isEmpty, true);
    });

    test('should detect deletion on beta side', () {
      // 基线有一个文件
      final baseEntries = {
        'test.txt': FileMetadata(
          path: 'test.txt',
          isDirectory: false,
          size: 10,
          mtime: DateTime(2023, 1, 1),
        ),
      };
      final base = Snapshot(baseEntries);

      // Alpha保持不变
      final alpha = Snapshot(baseEntries);

      // Beta删除了文件
      final beta = Snapshot({});

      // 执行差异比较
      final plan = differ.reconcile(base, alpha, beta);

      // 验证结果：应从alpha删除文件
      expect(plan.alphaToBeta.length, 1);
      expect(plan.alphaToBeta[0].path, 'test.txt');
      expect(plan.alphaToBeta[0].type, ChangeType.delete);
    });

    test('should detect conflict when both sides modified', () {
      // 基线有一个文件
      final baseEntries = {
        'test.txt': FileMetadata(
          path: 'test.txt',
          isDirectory: false,
          size: 10,
          mtime: DateTime(2023, 1, 1),
        ),
      };
      final base = Snapshot(baseEntries);

      // Alpha修改了文件
      final alphaEntries = {
        'test.txt': FileMetadata(
          path: 'test.txt',
          isDirectory: false,
          size: 20, // 大小变化
          mtime: DateTime(2023, 1, 3), // 时间更新
        ),
      };
      final alpha = Snapshot(alphaEntries);

      // Beta也修改了文件
      final betaEntries = {
        'test.txt': FileMetadata(
          path: 'test.txt',
          isDirectory: false,
          size: 15, // 不同的大小变化
          mtime: DateTime(2023, 1, 2), // 时间也更新
        ),
      };
      final beta = Snapshot(betaEntries);

      // 执行差异比较
      final plan = differ.reconcile(base, alpha, beta);

      // 验证结果：应检测到冲突
      expect(plan.conflicts.length, 1);
      expect(plan.conflicts[0].path, 'test.txt');
    });

    // 添加更多测试用例...
  });
}
