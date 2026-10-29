import 'dart:convert';
import 'dart:io';

import 'package:logger/logger.dart';
import 'package:mpeg_codec/mpeg_codec.dart';
import 'package:test/test.dart';

List<int> uint32(int value) => [
      (value >> 24) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 8) & 0xFF,
      value & 0xFF,
    ];

List<int> uint64(int value) => [...uint32(value >> 32), ...uint32(value)];

List<int> box(String type, List<int> payload) => [
      ...uint32(8 + payload.length),
      ...latin1.encode(type),
      ...payload,
    ];

void main() {
  late Directory dir;

  setUpAll(() => Logger.level = Level.off);

  setUp(() => dir = Directory.systemTemp.createTempSync('mp4_read_test_'));

  tearDown(() => dir.deleteSync(recursive: true));

  MP4Handler open(List<int> mvhdPayload) {
    final file = File('${dir.path}/song.m4a')
      ..writeAsBytesSync([
        ...box('ftyp', [...latin1.encode('M4A '), 0, 0, 0, 0]),
        ...box('moov', box('mvhd', mvhdPayload)),
      ]);
    return MP4Handler(file.path);
  }

  group('mvhd', () {
    test('reads the times, timescale and duration of a version 0 atom', () {
      final handler = open([
        0, 0, 0, 0, // version and flags
        ...uint32(3000000000), // creation time
        ...uint32(3000000100), // modification time
        ...uint32(44100), // timescale
        ...uint32(441000), // duration
        ...List.filled(80, 0), // rate, volume, matrix, next track id, ...
      ]);

      expect(handler.getMetadata<int>('creationTime'), 3000000000);
      expect(handler.getMetadata<int>('modificationTime'), 3000000100);
      expect(handler.getMetadata<int>('timescale'), 44100);
      expect(handler.getMetadata<int>('durationTicks'), 441000);
      expect(handler.getMetadata<int>('duration'), 10000); // milliseconds
    });

    test('reads a version 1 atom with 64-bit times', () {
      final handler = open([
        1, 0, 0, 0, // version and flags
        ...uint64(5000000000), // creation time
        ...uint64(5000000200), // modification time
        ...uint32(48000), // timescale
        ...uint64(6000000000), // duration, past 32 bits
        ...List.filled(80, 0),
      ]);

      expect(handler.getMetadata<int>('creationTime'), 5000000000);
      expect(handler.getMetadata<int>('modificationTime'), 5000000200);
      expect(handler.getMetadata<int>('timescale'), 48000);
      expect(handler.getMetadata<int>('durationTicks'), 6000000000);
      expect(handler.getMetadata<int>('duration'), 125000000);
    });

    test('ignores an atom that is too short', () {
      final handler = open([0, 0, 0, 0, 1, 2, 3]);

      expect(handler.metadata.contains('duration'), isFalse);
      expect(handler.metadata.contains('timescale'), isFalse);
    });

    test('has no duration when the timescale is zero', () {
      final handler = open([
        0, 0, 0, 0,
        ...uint32(0),
        ...uint32(0),
        ...uint32(0), // timescale
        ...uint32(1000),
        ...List.filled(80, 0),
      ]);

      expect(handler.metadata.contains('duration'), isFalse);
      expect(handler.getMetadata<int>('durationTicks'), 1000);
    });
  });
}
