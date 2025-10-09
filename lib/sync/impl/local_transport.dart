import '../stager.dart';
import '../transport.dart';

class LocalTransport implements Transport {
  final List<Function(StagingData)> _subscribers = [];

  // 添加订阅者机制，允许端点监听数据传输
  void subscribe(Function(StagingData) callback) {
    _subscribers.add(callback);
  }

  void unsubscribe(Function(StagingData) callback) {
    _subscribers.remove(callback);
  }

  @override
  Stream<StagingData> receive() async* {
    // 保留原有的流实现
    // 在实际应用中，这里可以结合订阅者机制
  }

  @override
  Future<void> send(StagingData data) async {
    // 通知所有订阅者有新数据到达
    for (final callback in _subscribers) {
      callback(data);
    }
  }
}
