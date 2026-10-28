import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:logger/logger.dart';
import 'package:mpeg_codec/mpeg_codec.dart';
import 'package:test/test.dart';

/// Stand-in for MPEG audio. It has no 0xFF sync bytes, so the parser does not
/// find frames in it, and it is long enough to catch an off-by-N copy.
final Uint8List audio = Uint8List.fromList(
  List.generate(5000, (i) => (i * 7 + 3) % 200),
);

List<int> syncSafe(int value) => [
      (value >> 21) & 0x7F,
      (value >> 14) & 0x7F,
      (value >> 7) & 0x7F,
      value & 0x7F,
    ];

List<int> uint32(int value) => [
      (value >> 24) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 8) & 0xFF,
      value & 0xFF,
    ];

List<int> frame(String id, List<int> body, int version, {int flags = 0}) => [
      ...ascii.encode(id),
      ...(version == 4 ? syncSafe(body.length) : uint32(body.length)),
      flags >> 8,
      flags & 0xFF,
      ...body,
    ];

List<int> utf8Text(String text) => [3, ...utf8.encode(text)];

List<int> latin1Text(String text) => [0, ...latin1.encode(text)];

List<int> id3Tag(int version, List<List<int>> frames, {int padding = 0}) {
  final body = [for (final f in frames) ...f, ...List.filled(padding, 0)];
  return [
    ...ascii.encode('ID3'),
    version,
    0,
    0,
    ...syncSafe(body.length),
    ...body,
  ];
}

/// A 128-byte ID3v1 tag.
List<int> id3v1Tag() {
  final tag = Uint8List(128);
  tag.setRange(0, 3, ascii.encode('TAG'));
  tag.setRange(3, 3 + 6, ascii.encode('Old v1'));
  return tag;
}

/// The frames of the ID3v2 tag at the start of [bytes], as id -> bodies, plus
/// the offset where the audio starts.
({int version, Map<String, List<Uint8List>> frames, int audioStart}) readTag(
  Uint8List bytes,
) {
  expect(ascii.decode(bytes.sublist(0, 3)), 'ID3', reason: 'no ID3v2 header');
  final version = bytes[3];
  final size = (bytes[6] << 21) | (bytes[7] << 14) | (bytes[8] << 7) | bytes[9];
  final data = ByteData.sublistView(bytes);
  final frames = <String, List<Uint8List>>{};
  var offset = 10;
  while (offset + 10 <= 10 + size && bytes[offset] != 0) {
    final id = ascii.decode(bytes.sublist(offset, offset + 4));
    final frameSize = version == 4
        ? (bytes[offset + 4] << 21) |
            (bytes[offset + 5] << 14) |
            (bytes[offset + 6] << 7) |
            bytes[offset + 7]
        : data.getUint32(offset + 4);
    frames
        .putIfAbsent(id, () => [])
        .add(bytes.sublist(offset + 10, offset + 10 + frameSize));
    offset += 10 + frameSize;
  }
  expect(offset, lessThanOrEqualTo(10 + size), reason: 'frame ran past tag');
  return (version: version, frames: frames, audioStart: 10 + size);
}

void main() {
  late Directory dir;
  var counter = 0;

  setUpAll(() => Logger.level = Level.off);

  setUp(() => dir = Directory.systemTemp.createTempSync('id3_write_test_'));

  tearDown(() => dir.deleteSync(recursive: true));

  File writeFile(List<int> bytes) {
    final file = File('${dir.path}/song${counter++}.mp3');
    file.writeAsBytesSync(bytes);
    return file;
  }

  group('applyMetadataChanges', () {
    test('keeps the audio byte-for-byte and the other frames (ID3v2.4)', () async {
      final file = writeFile([
        ...id3Tag(4, [
          frame('TIT2', utf8Text('Old title'), 4),
          frame('TPE1', utf8Text('Some artist'), 4),
        ]),
        ...audio,
      ]);

      final handler = ID3Handler(file.path);
      expect(handler.getMetadata<String>('title'), 'Old title');
      handler.updateMetadata({'title': 'New title'});
      await handler.applyMetadataChanges();

      final tag = readTag(file.readAsBytesSync());
      expect(tag.version, 4);
      expect(file.readAsBytesSync().sublist(tag.audioStart), audio);

      final reread = ID3Handler(file.path);
      expect(reread.getMetadata<String>('title'), 'New title');
      expect(reread.getMetadata<String>('artist'), 'Some artist');
      expect(handler.getMetadata<String>('title'), 'New title');
    });

    test('keeps ID3v2.3 as ID3v2.3, with plain frame sizes', () async {
      // 200 bytes is 0x00C8 as a plain size but 0x0148 as a synchsafe one, so
      // a wrong size encoding corrupts this frame.
      final longComment = 'x' * 200;
      final file = writeFile([
        ...id3Tag(3, [
          frame('TIT2', latin1Text('Old title'), 3),
          frame('TALB', latin1Text(longComment), 3),
        ]),
        ...audio,
      ]);

      final handler = ID3Handler(file.path);
      handler.updateMetadata({'title': 'New title'});
      await handler.applyMetadataChanges();

      final bytes = file.readAsBytesSync();
      final tag = readTag(bytes);
      expect(tag.version, 3);
      expect(bytes.sublist(tag.audioStart), audio);
      expect(tag.frames['TALB']!.single, latin1Text(longComment));

      final reread = ID3Handler(file.path);
      expect(reread.getMetadata<String>('title'), 'New title');
      expect(reread.getMetadata<String>('album'), longComment);
    });

    test('writes text that ID3v2.3 cannot store as ISO-8859-1 as UTF-16',
        () async {
      final file = writeFile([
        ...id3Tag(3, [frame('TPE1', latin1Text('x'), 3)]),
        ...audio,
      ]);

      final handler = ID3Handler(file.path);
      handler.updateMetadata({'title': 'Café', 'album': '日本語'});
      await handler.applyMetadataChanges();

      final reread = ID3Handler(file.path);
      expect(reread.getMetadata<String>('title'), 'Café');
      expect(reread.getMetadata<String>('album'), '日本語');
    });

    test('does not duplicate an existing ID3v1 tag', () async {
      final v1 = id3v1Tag();
      final file = writeFile([
        ...id3Tag(4, [frame('TIT2', utf8Text('Old title'), 4)]),
        ...audio,
        ...v1,
      ]);

      final handler = ID3Handler(file.path);
      handler.updateMetadata({'title': 'New title'});
      await handler.applyMetadataChanges();

      final bytes = file.readAsBytesSync();
      final tag = readTag(bytes);
      expect(bytes.sublist(tag.audioStart), [...audio, ...v1]);
    });

    test('does not add an ID3v1 tag to a file that had none', () async {
      final file = writeFile([
        ...id3Tag(4, [frame('TIT2', utf8Text('Old title'), 4)]),
        ...audio,
      ]);

      final handler = ID3Handler(file.path);
      handler.updateMetadata({'title': 'New title'});
      await handler.applyMetadataChanges();

      final bytes = file.readAsBytesSync();
      expect(bytes.sublist(readTag(bytes).audioStart), audio);
    });

    test('adds a tag to a file without one', () async {
      final file = writeFile(audio);

      final handler = ID3Handler(file.path);
      handler.addMetadata({'title': 'Brand new', 'artist': 'Someone'});
      await handler.applyMetadataChanges();

      final bytes = file.readAsBytesSync();
      final tag = readTag(bytes);
      expect(tag.version, 4);
      expect(bytes.sublist(tag.audioStart), audio);

      final reread = ID3Handler(file.path);
      expect(reread.getMetadata<String>('title'), 'Brand new');
      expect(reread.getMetadata<String>('artist'), 'Someone');
    });

    test('skips padding and the footer-less size of the old tag', () async {
      final file = writeFile([
        ...id3Tag(4, [frame('TIT2', utf8Text('Old title'), 4)], padding: 300),
        ...audio,
      ]);

      final handler = ID3Handler(file.path);
      handler.updateMetadata({'title': 'New title'});
      await handler.applyMetadataChanges();

      final bytes = file.readAsBytesSync();
      expect(bytes.sublist(readTag(bytes).audioStart), audio);
    });

    test('keeps frame flags and frames it cannot parse', () async {
      final raw = Uint8List.fromList([1, 2, 3, 4, 5]);
      final file = writeFile([
        ...id3Tag(4, [
          frame('PRIV', raw, 4, flags: 0x4000),
          frame('TIT2', utf8Text('Old title'), 4),
        ]),
        ...audio,
      ]);

      final handler = ID3Handler(file.path);
      handler.updateMetadata({'title': 'New title'});
      await handler.applyMetadataChanges();

      final bytes = file.readAsBytesSync();
      final tag = readTag(bytes);
      expect(tag.frames['PRIV']!.single, raw);
      // The flags sit in the two bytes before the body of the first frame.
      expect(bytes.sublist(18, 20), [0x40, 0x00]);
    });

    test('replaces every frame with the same ID', () async {
      final file = writeFile([
        ...id3Tag(4, [
          frame('COMM', [3, ...ascii.encode('eng'), 0, ...utf8.encode('a')], 4),
          frame('COMM', [3, ...ascii.encode('eng'), 0, ...utf8.encode('b')], 4),
          frame('TIT2', utf8Text('Title'), 4),
        ]),
        ...audio,
      ]);

      final handler = ID3Handler(file.path);
      handler.updateMetadata({'comment': 'only one'});
      await handler.applyMetadataChanges();

      final tag = readTag(file.readAsBytesSync());
      expect(tag.frames['COMM'], hasLength(1));
      expect(
        tag.frames['COMM']!.single,
        [3, ...ascii.encode('eng'), 0, ...utf8.encode('only one')],
      );
      expect(tag.frames['TIT2'], hasLength(1));
    });

    test('removes a key from the file and from the metadata', () async {
      final file = writeFile([
        ...id3Tag(4, [
          frame('TIT2', utf8Text('Title'), 4),
          frame('TPE1', utf8Text('Artist'), 4),
        ]),
        ...audio,
      ]);

      final handler = ID3Handler(file.path);
      expect(handler.metadata.contains('artist'), isTrue);
      handler.removeMetadata(['artist']);
      await handler.applyMetadataChanges();

      expect(handler.metadata.contains('artist'), isFalse);
      expect(handler.getMetadata<String>('title'), 'Title');
      expect(readTag(file.readAsBytesSync()).frames.containsKey('TPE1'), isFalse);
    });

    test('clears the queue so a second apply does not repeat the work',
        () async {
      final file = writeFile([
        ...id3Tag(4, [frame('TIT2', utf8Text('Title'), 4)]),
        ...audio,
      ]);

      final handler = ID3Handler(file.path);
      handler.updateMetadata({'title': 'One'});
      await handler.applyMetadataChanges();
      expect(handler.pendingOperations, isEmpty);

      handler.updateMetadata({'title': 'Two'});
      await handler.applyMetadataChanges();
      expect(ID3Handler(file.path).getMetadata<String>('title'), 'Two');
    });
  });

  group('values', () {
    test('track and disc pairs are stored as "number/total" text', () async {
      final file = writeFile(audio);

      final handler = ID3Handler(file.path);
      handler.addMetadata({
        'track': [3, 12],
        'discNumber': 2,
        'bpm': 120,
      });
      await handler.applyMetadataChanges();

      final tag = readTag(file.readAsBytesSync());
      expect(utf8.decode(tag.frames['TRCK']!.single.sublist(1)), '3/12');
      expect(utf8.decode(tag.frames['TPOS']!.single.sublist(1)), '2');
      expect(utf8.decode(tag.frames['TBPM']!.single.sublist(1)), '120');

      final reread = ID3Handler(file.path);
      expect(reread.getMetadata<List<int>>('track'), [3, 12]);
    });

    test('year goes in TDRC for ID3v2.4 and TYER for ID3v2.3', () async {
      final v4 = writeFile([
        ...id3Tag(4, [frame('TIT2', utf8Text('t'), 4)]),
        ...audio,
      ]);
      final v3 = writeFile([
        ...id3Tag(3, [frame('TIT2', latin1Text('t'), 3)]),
        ...audio,
      ]);

      for (final file in [v4, v3]) {
        final handler = ID3Handler(file.path);
        handler.updateMetadata({'year': '1999'});
        await handler.applyMetadataChanges();
      }

      final frames4 = readTag(v4.readAsBytesSync()).frames;
      final frames3 = readTag(v3.readAsBytesSync()).frames;
      expect(frames4.containsKey('TDRC'), isTrue);
      expect(frames4.containsKey('TYER'), isFalse);
      expect(frames3.containsKey('TYER'), isTrue);
    });

    test('lists are joined with null separators in ID3v2.4', () async {
      final file = writeFile(audio);

      final handler = ID3Handler(file.path);
      handler.addMetadata({
        'artist': ['First', 'Second'],
      });
      await handler.applyMetadataChanges();

      final body = readTag(file.readAsBytesSync()).frames['TPE1']!.single;
      expect(body, [3, ...utf8.encode('First'), 0, ...utf8.encode('Second')]);
      expect(
        ID3Handler(file.path).getMetadata<List<String>>('artist'),
        ['First', 'Second'],
      );
    });

    test('writes a picture as an APIC frame', () async {
      final file = writeFile(audio);
      final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4]);

      final handler = ID3Handler(file.path);
      handler.addMetadata({'picture': jpeg});
      await handler.applyMetadataChanges();

      final body = readTag(file.readAsBytesSync()).frames['APIC']!.single;
      expect(body.sublist(0, 1 + 10 + 1), [
        0,
        ...ascii.encode('image/jpeg'),
        0,
      ]);
      expect(body.sublist(body.length - jpeg.length), jpeg);
    });

    test('writes a URL as plain ISO-8859-1 with no encoding byte', () async {
      final file = writeFile(audio);

      final handler = ID3Handler(file.path);
      handler.addMetadata({'website': 'https://example.com'});
      await handler.applyMetadataChanges();

      final body = readTag(file.readAsBytesSync()).frames['WOAR']!.single;
      expect(ascii.decode(body), 'https://example.com');
    });
  });

  group('failures', () {
    test('an invalid key throws and leaves the file untouched', () async {
      final original = Uint8List.fromList([
        ...id3Tag(4, [frame('TIT2', utf8Text('Title'), 4)]),
        ...audio,
      ]);
      final file = writeFile(original);

      final handler = ID3Handler(file.path);
      handler.updateMetadata({'title': 'Changed', 'not a frame': 'x'});

      await expectLater(
        handler.applyMetadataChanges(),
        throwsA(isA<ID3Exception>()),
      );
      expect(file.readAsBytesSync(), original);
      expect(File('${file.path}.tmp').existsSync(), isFalse);
      expect(handler.getMetadata<String>('title'), 'Title');
    });

    test('a value the frame cannot hold throws and leaves the file untouched',
        () async {
      final original = Uint8List.fromList([
        ...id3Tag(4, [frame('TIT2', utf8Text('Title'), 4)]),
        ...audio,
      ]);
      final file = writeFile(original);

      final handler = ID3Handler(file.path);
      handler.updateMetadata({'rating': 5});

      await expectLater(
        handler.applyMetadataChanges(),
        throwsA(isA<ID3Exception>()),
      );
      expect(file.readAsBytesSync(), original);
    });
  });

  group('intToBytes', () {
    test('writes big-endian bytes of the requested width', () {
      final handler = ID3Handler(writeFile(audio).path);
      expect(handler.intToBytes(5, 4), [0, 0, 0, 5]);
      expect(handler.intToBytes(0x0102, 2), [1, 2]);
      expect(handler.intToBytes(0x01020304, 4), [1, 2, 3, 4]);
      expect(handler.intToBytes(7, 1), [7]);
    });
  });
}
