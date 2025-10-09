import 'dart:io';

import '../differ.dart';
import '../stager.dart';

class SimpleStager implements Stager {
  final String alphaRoot;

  SimpleStager(this.alphaRoot);

  @override
  StagingData prepare(SyncPlan plan) {
    final changes = <Change>[];
    final chunks = <ByteChunk>[];

    for (final ch in plan.alphaToBeta) {
      changes.add(ch);
      if (ch.type == ChangeType.create || ch.type == ChangeType.modify) {
        if (ch.metadata != null && !ch.metadata!.isDirectory) {
          final file = File(_abs(alphaRoot, ch.path));
          if (file.existsSync()) {
            final data = file.readAsBytesSync();
            chunks.add(ByteChunk(ch.path, 0, data));
          }
        }
      }
    }

    return StagingData(metadataChanges: changes, dataChunks: chunks);
  }

  String _abs(String root, String rel) =>
      rel.startsWith(root) ? rel : '${root.endsWith('/') ? root.substring(0, root.length - 1) : root}/$rel';
}
