import 'differ.dart';

class ByteChunk {
  final String path;
  final int offset;
  final List<int> data;

  ByteChunk(this.path, this.offset, this.data);
}

class StagingData {
  final List<Change> metadataChanges;
  final List<ByteChunk> dataChunks;

  StagingData({
    required this.metadataChanges,
    required this.dataChunks,
  });
}

