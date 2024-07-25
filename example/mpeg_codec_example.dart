import 'dart:io';
import 'package:path/path.dart' as path;

import 'package:mpeg_codec/mpeg_codec.dart';

void main(List<String> args) async {
  if (args.isEmpty) {
    print("please provide a folder");
    return;
  }

  final folderPath = args.first;

  final folder = Directory(folderPath);

  if (!await folder.exists()) {
    print("folder does not exist");
    return;
  }

  final filePaths = <String>[];
  await for (FileSystemEntity el in folder.list(recursive: true)) {
    if (el is File) {
      if (path.extension(path.basename(el.path)) == '.m4a') {
        filePaths.add(el.path);
      }
    }
  }

  for (String filePath in filePaths) {
    final handler = MP4Handler(filePath);

    print("===[${path.basename(filePath)}]===");

    for (var entry in handler.metadata.asMap().entries) {
      if (entry.key == "cover") {
        continue;
      }
      print("[${entry.key.toUpperCase()}]");
      print("   |__${entry.value}");
    }

    // Queue multiple operations
    handler.addMetadata({'title': 'New Title'});
    handler.updateMetadata({'genre': 'New Genre'});
    handler.removeMetadata(['artist']);
    try {
      // Apply all queued changes at once
      await handler.applyMetadataChanges();
      print('Metadata changes applied successfully');
    } catch (e) {
      print('Failed to apply metadata changes: $e');
    }
  }
}
