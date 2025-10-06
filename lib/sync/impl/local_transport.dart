import '../stager.dart';
import '../transport.dart';

class LocalTransport implements Transport {
  StagingData? _last;

  @override
  Stream<StagingData> receive() async* {
    if (_last != null) {
      yield _last!;
      _last = null;
    }
  }

  @override
  Future<void> send(StagingData data) async {
    // For same-process demo we just store the last staging payload.
    _last = data;
  }
}

