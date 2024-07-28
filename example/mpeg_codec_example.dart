import 'dart:io';
import 'package:mpeg_codec/src/id3.dart';
import 'package:mpeg_codec/src/utils.dart';
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

  await for (FileSystemEntity el in folder.list(recursive: true)) {
    final fileExt = path.extension(path.basename(el.path));
    if (el is File) {
      if (['.m4a', '.m4p'].contains(fileExt)) {
        await handleMp4(el.path);
      } else if (['.mp3'].contains(fileExt)) {
        await handleMp3(el.path);
      }
    }
  }
}

Future<void> handleMp3(String filePath) async {
  final stopwatch = Stopwatch()..start();
  final handler = ID3Handler(filePath);
  stopwatch.stop();

  print("===[${path.basename(filePath)}]===");

  for (final entry in handler.metadata.asMap().entries) {
    if (entry.key == "cover" || entry.key == "picture") {
      continue;
    }
    print("[${entry.key.toUpperCase()}]");
    print("   |__${entry.value}");
  }

  // Queue multiple operations
  handler.addMetadata({'title': 'New Title', 'artist': 'Artist'});
  // handler.updateMetadata({'genre': 'New Genre'});
  // handler.removeMetadata(['artist']);
  try {
    // Apply all queued changes at once
    await handler.applyMetadataChanges();
    print('Metadata changes applied successfully');
  } catch (e) {
    print('Failed to apply metadata changes: $e');
  }

  print("Elapsed time: ${formatDuration(stopwatch.elapsed)}");
}

Future<void> handleMp4(String filePath) async {
  final stopwatch = Stopwatch()..start();
  final handler = MP4Handler(filePath);
  stopwatch.stop();

  print("===[${path.basename(filePath)}]===");

  for (final entry in handler.metadata.asMap().entries) {
    if (entry.key == "cover") {
      continue;
    }
    print("[${entry.key.toUpperCase()}]");
    print("   |__${entry.value}");
  }

  // Queue multiple operations
  // handler.addMetadata({'title': 'New Title', 'artist': 'Artist'});
  // handler.updateMetadata({'genre': 'New Genre'});
  // handler.removeMetadata(['artist']);
  // try {
  //   // Apply all queued changes at once
  //   await handler.applyMetadataChanges();
  //   print('Metadata changes applied successfully');
  // } catch (e) {
  //   print('Failed to apply metadata changes: $e');
  // }
  print("Elapsed MP4 time: ${formatDuration(stopwatch.elapsed)}");
}
