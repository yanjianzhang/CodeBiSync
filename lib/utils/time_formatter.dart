import '../models/sync_entry.dart';

/// 时间格式化工具类
class TimeFormatter {
  /// 将时间差格式化为易读的字符串
  /// 
  /// 例如：
  /// - 30秒前
  /// - 5分钟前
  /// - 2小时前
  /// - 3天前
  static String formatTimeAgo(DateTime? dateTime) {
    if (dateTime == null) {
      return '未知时间';
    }

    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inSeconds < 60) {
      return '${difference.inSeconds}秒前';
    } else if (difference.inMinutes < 60) {
      return '${difference.inMinutes}分钟前';
    } else if (difference.inHours < 24) {
      return '${difference.inHours}小时前';
    } else {
      return '${difference.inDays}天前';
    }
  }

  /// 根据同步状态和时间返回对应的状态显示文本
  /// 
  /// 状态规则：
  /// 1. 如果修改时间和上次同步时间相同，则显示为"已同步"
  /// 2. 如果同步状态为synced，则显示为"已同步"
  /// 3. 如果同步状态为failed，则显示为"同步失败"
  /// 4. 如果同步状态为pending，则显示上次修改时间
  static String formatSyncStatus(
    SyncStatus status, 
    DateTime? modifiedAt, 
    DateTime? lastSyncAt
  ) {
    // 如果修改时间和上次同步时间相同，则认为已同步
    if (modifiedAt != null && lastSyncAt != null && modifiedAt.isAtSameMomentAs(lastSyncAt)) {
      return '已同步';
    }
    
    switch (status) {
      case SyncStatus.synced:
        // 显示同步时间
        return lastSyncAt != null ? formatTimeAgo(lastSyncAt) : '已同步';
      case SyncStatus.failed:
        return lastSyncAt != null ? '${formatTimeAgo(lastSyncAt)}同步失败' : '同步失败';
      case SyncStatus.pending:
      default:
        // 显示文件修改时间
        return modifiedAt != null ? formatTimeAgo(modifiedAt) : '待同步';
    }
  }
}