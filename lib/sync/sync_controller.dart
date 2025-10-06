import 'session.dart';

class SyncController {
  final Map<String, Session> _sessions = {};

  /// 新建并启动一个 Session，返回一个 ID
  Future<String> createSession({
    required String sessionId,
    required Session session,
  }) async {
    _sessions[sessionId] = session;
    session.runLoop(); // 不等待，后台运行
    return sessionId;
  }

  /// 停止一个 Session
  void terminateSession(String sessionId) {
    final session = _sessions[sessionId];
    if (session != null) {
      session.cancel();
      _sessions.remove(sessionId);
    }
  }

  bool hasSession(String sessionId) {
    return _sessions.containsKey(sessionId);
  }
}
