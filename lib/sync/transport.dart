import 'stager.dart';

abstract class Transport {
  /// 发送 staging 数据到对端
  Future<void> send(StagingData data);

  /// 接收对端传来的 staging 数据（如果双向）
  Stream<StagingData> receive();
}
