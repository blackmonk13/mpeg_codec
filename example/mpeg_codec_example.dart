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
    try {
      final handler = MP4Handler(filePath);

      print("===[${path.basename(filePath)}]===");

      for (var entry in handler.metadata.asMap().entries) {
        if (entry.key == "cover") {
          continue;
        }
        print("[${entry.key.toUpperCase()}]");
        print("   |__${entry.value}");
      }

      final success = await handler.updateMetadata({
        'title': 'New Title',
        'artist': 'New Artist',
      });
      if (success) {
        print('Metadata updated successfully');
      } else {
        print('Failed to update metadata');
      }
    } on MP4Exception catch (e) {
      print('Error parsing MP4 file: $e');
    }
  }
}
