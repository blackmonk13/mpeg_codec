import 'dart:io';
import 'dart:typed_data';

import 'package:mpeg_codec/mpeg_codec.dart';
import 'package:path/path.dart' as path;

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
      await saveThumbnail(handler.metadata);
      continue;
    }
    print("[${entry.key.toUpperCase()}]");
    print("   |__${entry.value}");
    print("   |__${entry.value.runtimeType}");
  }

  // Queue multiple operations
  // handler.addMetadata({
  //   'title': 'New Title',
  //   'artist': 'Artist',
  // });
  // handler.updateMetadata({'genre': 'New Genre'});
  // handler.removeMetadata(['artist']);

  // try {
  //   // Apply all queued changes at once
  //   await handler.applyMetadataChanges();
  //   print('Metadata changes applied successfully');
  // } catch (e) {
  //   print('Failed to apply metadata changes: $e');
  // }

  print("Elapsed time: ${formatDuration(stopwatch.elapsed)}");
}

Future<void> handleMp4(String filePath) async {
  final stopwatch = Stopwatch()..start();
  final handler = MP4Handler(filePath);
  stopwatch.stop();

  print("===[${path.basename(filePath)}]===");

  for (final entry in handler.metadata.asMap().entries) {
    if (entry.key == "cover") {
      await saveThumbnail(handler.metadata);
      continue;
    }
    print("[${entry.key.toUpperCase()}]");
    print("   |__${entry.value}");
    print("   |__${entry.value.runtimeType}");
  }

  // Queue multiple operations
  // handler.addMetadata({
  //   'title': 'New Title',
  //   'artist': 'Artist',
  // });
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

Future<String?> saveThumbnail(Metadata metadata) async {
  Uint8List? imageData;
  if (metadata.get('cover') is Uint8List) {
    imageData = metadata.get('cover');
  } else if (metadata.get('picture') is Map<String, dynamic>) {
    imageData = metadata.get('picture')['data'];
  }

  if (imageData == null) {
    return null;
  }

  Uint8List encodedData = Uint8List.fromList(imageData);

  final thumbnailPath = path.join(
    path.dirname(metadata.get('filePath')),
    '${path.basenameWithoutExtension(metadata.get('filePath'))}.png',
  );

  final thumbnailFile = File(thumbnailPath);

  if (!await thumbnailFile.exists()) {
    await thumbnailFile.writeAsBytes(encodedData);
  }

  return thumbnailPath;
}
