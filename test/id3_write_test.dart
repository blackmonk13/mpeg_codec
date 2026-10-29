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

List<int> uint32be(int value) => [
      (value >> 24) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 8) & 0xFF,
      value & 0xFF,
    ];

List<int> id3Tag(
  int version,
  List<List<int>> frames, {
  int padding = 0,
  bool footer = false,
}) {
  final body = [for (final f in frames) ...f, ...List.filled(padding, 0)];
  return [
    ...ascii.encode('ID3'),
    version,
    0,
    footer ? 0x10 : 0,
    ...syncSafe(body.length),
    ...body,
    if (footer) ...[
      ...ascii.encode('3DI'),
      version,
      0,
      0x10,
      ...syncSafe(body.length),
    ],
  ];
}

/// A 128-byte ID3v1.1 tag.
Uint8List id3v1Tag() {
  final tag = Uint8List(128);
  tag.setRange(0, 3, ascii.encode('TAG'));
  tag.setRange(3, 3 + 6, ascii.encode('Old v1'));
  tag.setRange(33, 33 + 10, ascii.encode('Old artist'));
  tag.setRange(63, 63 + 9, ascii.encode('Old album'));
  tag.setRange(93, 93 + 4, ascii.encode('1990'));
  tag.setRange(97, 97 + 11, ascii.encode('Old comment'));
  tag[126] = 4; // track
  tag[127] = 17; // Rock
  return tag;
}

String zeroTerminated(Uint8List bytes, int start, int length) {
  final field = bytes.sublist(start, start + length);
  final end = field.indexOf(0);
  return latin1.decode(end == -1 ? field : field.sublist(0, end));
}

/// The frames of the ID3v2 tag at the start of [bytes], as id -> bodies, plus
/// the offset where the audio starts.
/// Undoes unsynchronization: every 0xFF 0x00 becomes 0xFF.
Uint8List deUnsync(List<int> data) {
  final out = <int>[];
  for (var i = 0; i < data.length; i++) {
    out.add(data[i]);
    if (data[i] == 0xFF && i + 1 < data.length && data[i + 1] == 0) i++;
  }
  return Uint8List.fromList(out);
}

/// Whether [data] has a 0xFF followed by a byte that looks like the start of
/// an MPEG frame.
bool hasFalseSync(List<int> data) {
  for (var i = 0; i < data.length; i++) {
    if (data[i] == 0xFF && (i + 1 == data.length || data[i + 1] >= 0xE0)) {
      return true;
    }
  }
  return false;
}

({
  int version,
  int flags,
  Map<String, List<Uint8List>> frames,
  int audioStart,
}) readTag(Uint8List bytes) {
  expect(ascii.decode(bytes.sublist(0, 3)), 'ID3', reason: 'no ID3v2 header');
  final version = bytes[3];
  final flags = bytes[5];
  final size = (bytes[6] << 21) | (bytes[7] << 14) | (bytes[8] << 7) | bytes[9];

  // ID3v2.3 unsynchronizes the whole tag, ID3v2.4 each frame.
  var body = bytes.sublist(10, 10 + size);
  if (version == 3 && flags & 0x80 != 0) body = deUnsync(body);
  final data = ByteData.sublistView(body);
  final frames = <String, List<Uint8List>>{};
  var offset = 0;
  while (offset + 10 <= body.length && body[offset] != 0) {
    final id = ascii.decode(body.sublist(offset, offset + 4));
    final frameSize = version == 4
        ? (body[offset + 4] << 21) |
            (body[offset + 5] << 14) |
            (body[offset + 6] << 7) |
            body[offset + 7]
        : data.getUint32(offset + 4);
    final frameFlags = data.getUint16(offset + 8);
    var frameData = body.sublist(offset + 10, offset + 10 + frameSize);
    if (version == 4 && frameFlags & 0x0002 != 0) {
      frameData = deUnsync(frameData);
    }
    frames.putIfAbsent(id, () => []).add(frameData);
    offset += 10 + frameSize;
  }
  expect(offset, lessThanOrEqualTo(body.length), reason: 'frame ran past tag');
  return (version: version, flags: flags, frames: frames, audioStart: 10 + size);
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

    test('does not duplicate an existing ID3v1 tag, and keeps it consistent',
        () async {
      final v1 = id3v1Tag();
      final file = writeFile([
        ...id3Tag(4, [frame('TIT2', utf8Text('Old title'), 4)]),
        ...audio,
        ...v1,
      ]);

      final handler = ID3Handler(file.path);
      handler.updateMetadata({
        'title': 'New title',
        'year': '1999',
        'genre': 'Jazz',
        'track': [7, 12],
      });
      await handler.applyMetadataChanges();

      final bytes = file.readAsBytesSync();
      final tag = readTag(bytes);
      expect(bytes.length, tag.audioStart + audio.length + 128);
      expect(
        bytes.sublist(tag.audioStart, tag.audioStart + audio.length),
        audio,
      );

      final tail = bytes.sublist(bytes.length - 128);
      expect(zeroTerminated(tail, 0, 3), 'TAG');
      expect(zeroTerminated(tail, 3, 30), 'New title');
      expect(zeroTerminated(tail, 63, 30), 'Old album'); // not changed
      expect(zeroTerminated(tail, 93, 4), '1999');
      expect(zeroTerminated(tail, 97, 28), 'Old comment'); // not changed
      expect(tail[126], 7);
      expect(tail[127], 8); // Jazz
    });

    test('blanks the ID3v1 fields of a removed key', () async {
      final file = writeFile([
        ...id3Tag(4, [frame('TIT2', utf8Text('Old title'), 4)]),
        ...audio,
        ...id3v1Tag(),
      ]);

      final handler = ID3Handler(file.path);
      handler.removeMetadata(['artist', 'genre', 'track']);
      await handler.applyMetadataChanges();

      final bytes = file.readAsBytesSync();
      final tail = bytes.sublist(bytes.length - 128);
      expect(zeroTerminated(tail, 33, 30), '');
      expect(tail[126], 0);
      expect(tail[127], 255);
      expect(zeroTerminated(tail, 3, 30), 'Old v1'); // not changed
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

    test('skips the footer of the old tag', () async {
      final file = writeFile([
        ...id3Tag(4, [frame('TIT2', utf8Text('Old title'), 4)], footer: true),
        ...audio,
      ]);

      final handler = ID3Handler(file.path);
      handler.updateMetadata({'title': 'New title'});
      await handler.applyMetadataChanges();

      final bytes = file.readAsBytesSync();
      expect(bytes[5], 0, reason: 'the footer flag must be cleared');
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

  group('more frames', () {
    test('year is readable again after it is written to TDRC', () async {
      final file = writeFile([
        ...id3Tag(4, [frame('TIT2', utf8Text('t'), 4)]),
        ...audio,
      ]);

      final handler = ID3Handler(file.path);
      handler.updateMetadata({'year': '1999'});
      await handler.applyMetadataChanges();

      expect(handler.getMetadata<String>('year'), '1999');
      expect(handler.getMetadata<String>('recordingTime'), '1999');
    });

    test('year is the first four digits of a full recording date', () {
      final file = writeFile([
        ...id3Tag(4, [frame('TDRC', utf8Text('2001-05-03'), 4)]),
        ...audio,
      ]);

      final handler = ID3Handler(file.path);
      expect(handler.getMetadata<String>('year'), '2001');
      expect(handler.getMetadata<String>('recordingTime'), '2001-05-03');
    });

    test('user text frames are told apart by description', () async {
      final file = writeFile(audio);

      final handler = ID3Handler(file.path);
      handler.addMetadata({'TXXX:Mood': 'calm', 'TXXX:Source': 'vinyl'});
      await handler.applyMetadataChanges();

      handler.updateMetadata({'TXXX:Mood': 'lively'});
      await handler.applyMetadataChanges();

      var frames = readTag(file.readAsBytesSync()).frames['TXXX']!;
      expect(
        frames.map((f) => utf8.decode(f.sublist(1))).toList(),
        ['Mood\x00lively', 'Source\x00vinyl'],
      );

      handler.removeMetadata(['TXXX:Source']);
      await handler.applyMetadataChanges();
      frames = readTag(file.readAsBytesSync()).frames['TXXX']!;
      expect(frames, hasLength(1));
      expect(utf8.decode(frames.single.sublist(1)), 'Mood\x00lively');
    });

    test('writes a user text frame given as a map, as reading produces it',
        () async {
      final file = writeFile(audio);

      final handler = ID3Handler(file.path);
      handler.addMetadata({
        'userDefinedText': {'description': 'Mood', 'value': 'calm'},
      });
      await handler.applyMetadataChanges();

      expect(
        handler.getMetadata<Map<String, dynamic>>('userDefinedText'),
        {'description': 'Mood', 'value': 'calm'},
      );
    });

    test('writes and reads a rating, and keeps other owners', () async {
      final other = [...ascii.encode('someone@example.com'), 0, 64, 0, 0, 0, 1];
      final file = writeFile([
        ...id3Tag(4, [frame('POPM', other, 4)]),
        ...audio,
      ]);

      final handler = ID3Handler(file.path);
      handler.updateMetadata({'rating': 200});
      await handler.applyMetadataChanges();

      expect(handler.getMetadata<int>('rating'), 200);
      var popm = readTag(file.readAsBytesSync()).frames['POPM']!;
      expect(popm, hasLength(2));

      handler.removeMetadata(['rating']);
      await handler.applyMetadataChanges();
      popm = readTag(file.readAsBytesSync()).frames['POPM']!;
      expect(popm.single, other);
    });

    test('an out-of-range rating throws', () async {
      final file = writeFile(audio);

      final handler = ID3Handler(file.path);
      handler.updateMetadata({'rating': 300});

      await expectLater(
        handler.applyMetadataChanges(),
        throwsA(isA<ID3Exception>()),
      );
    });

    test('writes several pictures and reads them all', () async {
      final file = writeFile(audio);
      final front = Uint8List.fromList([0xFF, 0xD8, 0xFF, 1, 2, 3]);
      final back = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 4, 5, 6]);

      final handler = ID3Handler(file.path);
      handler.addMetadata({
        'picture': [
          front,
          {'data': back, 'pictureType': 4, 'description': 'Back'},
        ],
      });
      await handler.applyMetadataChanges();

      expect(readTag(file.readAsBytesSync()).frames['APIC'], hasLength(2));
      final pictures = handler.getMetadata<List>('pictures')!;
      expect(pictures, hasLength(2));
      expect(pictures[0]['data'], front);
      expect(pictures[0]['mimeType'], 'image/jpeg');
      expect(pictures[1]['data'], back);
      expect(pictures[1]['mimeType'], 'image/png');
      expect(pictures[1]['pictureType'], 4);
      expect(pictures[1]['description'], 'Back');
    });

    test('adding a picture keeps the others, updating replaces them',
        () async {
      final file = writeFile(audio);
      final front = Uint8List.fromList([0xFF, 0xD8, 0xFF, 1, 2, 3]);
      final back = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 4, 5, 6]);
      final other = Uint8List.fromList([0xFF, 0xD8, 0xFF, 7, 8, 9]);

      final first = ID3Handler(file.path);
      first.addMetadata({'picture': front});
      await first.applyMetadataChanges();

      final second = ID3Handler(file.path);
      second.addMetadata({
        'picture': {'data': back, 'pictureType': 4},
      });
      await second.applyMetadataChanges();

      expect(readTag(file.readAsBytesSync()).frames['APIC'], hasLength(2));
      final pictures = ID3Handler(file.path).getMetadata<List>('pictures')!;
      expect(pictures.map((p) => p['data']), [front, back]);

      final third = ID3Handler(file.path);
      third.updateMetadata({'picture': other});
      await third.applyMetadataChanges();
      expect(readTag(file.readAsBytesSync()).frames['APIC'], hasLength(1));
    });

    test('a picture read from one file can be written to another', () async {
      final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 9, 9, 9]);
      final source = writeFile([
        ...id3Tag(4, [
          frame('APIC', [
            0, ...ascii.encode('image/jpeg'), 0, 3, ...ascii.encode('Art'), 0,
            ...jpeg,
          ], 4),
        ]),
        ...audio,
      ]);
      final target = writeFile(audio);

      final picture = ID3Handler(source.path).getMetadata<Map>('picture')!;
      final handler = ID3Handler(target.path);
      handler.addMetadata({'picture': picture});
      await handler.applyMetadataChanges();

      final reread = ID3Handler(target.path).getMetadata<Map>('picture')!;
      expect(reread['data'], jpeg);
      expect(reread['description'], 'Art');
    });

    test('a comment read from a file can be written back', () async {
      final file = writeFile([
        ...id3Tag(4, [
          frame('COMM', [
            3, ...ascii.encode('fra'), ...utf8.encode('note'), 0,
            ...utf8.encode('bonjour'),
          ], 4),
        ]),
        ...audio,
      ]);

      final handler = ID3Handler(file.path);
      final comment = handler.getMetadata<Map>('comment')!;
      expect(comment['language'], 'fra');
      handler.updateMetadata({'comment': comment});
      await handler.applyMetadataChanges();

      expect(handler.getMetadata<Map>('comment'), comment);
    });
  });

  group('reading', () {
    test('reads frames whose last string is not terminated', () {
      final file = writeFile([
        ...id3Tag(4, [
          frame('USLT', [
            3, ...ascii.encode('eng'), ...utf8.encode('d'), 0,
            ...utf8.encode('la la la'),
          ], 4),
          frame('TXXX', [3, ...utf8.encode('Mood'), 0, ...utf8.encode('calm')], 4),
        ]),
        ...audio,
      ]);

      final handler = ID3Handler(file.path);
      expect(handler.getMetadata<Map>('unsynchronizedLyrics')!['text'], 'la la la');
      expect(
        handler.getMetadata<Map>('userDefinedText'),
        {'description': 'Mood', 'value': 'calm'},
      );
    });
  });

  group('padding and in-place writes', () {
    test('a tag that fits in its padding is written in place', () async {
      final v1 = id3v1Tag();
      final file = writeFile([
        ...id3Tag(4, [frame('TIT2', utf8Text('Old title'), 4)], padding: 300),
        ...audio,
        ...v1,
      ]);
      final before = file.readAsBytesSync();
      final oldStart = readTag(before).audioStart;

      final handler = ID3Handler(file.path);
      handler.updateMetadata({'title': 'A new title', 'artist': 'Someone'});
      await handler.applyMetadataChanges();

      final bytes = file.readAsBytesSync();
      // Same length, same audio start: nothing was copied or moved.
      expect(bytes.length, before.length);
      expect(readTag(bytes).audioStart, oldStart);
      expect(bytes.sublist(oldStart, oldStart + audio.length), audio);
      expect(File('${file.path}.tmp').existsSync(), isFalse);

      final reread = ID3Handler(file.path);
      expect(reread.getMetadata<String>('title'), 'A new title');
      expect(reread.getMetadata<String>('artist'), 'Someone');

      // The ID3v1 tag follows the change, in place too.
      final tail = bytes.sublist(bytes.length - 128);
      expect(zeroTerminated(tail, 3, 30), 'A new title');
      expect(zeroTerminated(tail, 33, 30), 'Someone');
      expect(zeroTerminated(tail, 63, 30), 'Old album');
    });

    test('a shorter tag leaves the rest of the space as padding', () async {
      final file = writeFile([
        ...id3Tag(4, [
          frame('TIT2', utf8Text('Old title'), 4),
          frame('TPE1', utf8Text('x' * 100), 4),
        ]),
        ...audio,
      ]);
      final oldStart = readTag(file.readAsBytesSync()).audioStart;

      final handler = ID3Handler(file.path);
      handler.removeMetadata(['artist']);
      await handler.applyMetadataChanges();

      final bytes = file.readAsBytesSync();
      expect(readTag(bytes).audioStart, oldStart);
      expect(bytes.sublist(oldStart), audio);
      expect(ID3Handler(file.path).metadata.contains('artist'), isFalse);
      expect(ID3Handler(file.path).getMetadata<String>('title'), 'Old title');
    });

    test('a tag that has to grow is rewritten with padding', () async {
      final file = writeFile([
        ...id3Tag(4, [frame('TIT2', utf8Text('Old title'), 4)]),
        ...audio,
      ]);

      final handler = ID3Handler(file.path);
      handler.updateMetadata({'title': 'A much longer title than before'});
      await handler.applyMetadataChanges();

      final bytes = file.readAsBytesSync();
      final tag = readTag(bytes);
      expect(bytes.sublist(tag.audioStart), audio);
      // 10 bytes of frame header and one of encoding come with the title.
      final used = 10 + 10 + 1 + 'A much longer title than before'.length;
      expect(tag.audioStart - used, ID3Handler.tagPadding);

      // Now a second edit that is a bit longer fits without moving the audio.
      final second = ID3Handler(file.path);
      second.updateMetadata({'artist': 'Some artist', 'album': 'Some album'});
      await second.applyMetadataChanges();

      final again = file.readAsBytesSync();
      expect(readTag(again).audioStart, tag.audioStart);
      expect(again.sublist(tag.audioStart), audio);
      expect(ID3Handler(file.path).getMetadata<String>('album'), 'Some album');
    });

    test('inPlace: false always writes a new file', () async {
      final file = writeFile([
        ...id3Tag(4, [frame('TIT2', utf8Text('Old title'), 4)], padding: 300),
        ...audio,
      ]);
      final oldStart = readTag(file.readAsBytesSync()).audioStart;

      final handler = ID3Handler(file.path);
      handler.updateMetadata({'title': 'New title'});
      await handler.applyMetadataChanges(inPlace: false);

      final bytes = file.readAsBytesSync();
      final tag = readTag(bytes);
      expect(tag.audioStart, isNot(oldStart));
      expect(bytes.sublist(tag.audioStart), audio);
      expect(ID3Handler(file.path).getMetadata<String>('title'), 'New title');
    });

    test('a value that cannot be stored still leaves a padded file untouched',
        () async {
      final file = writeFile([
        ...id3Tag(4, [frame('TIT2', utf8Text('Old title'), 4)], padding: 300),
        ...audio,
      ]);
      final before = file.readAsBytesSync();

      final handler = ID3Handler(file.path);
      handler.updateMetadata({'title': 'fine', 'rating': 300});

      await expectLater(
        handler.applyMetadataChanges(),
        throwsA(isA<ID3Exception>()),
      );
      expect(file.readAsBytesSync(), before);
    });
  });

  group('unsynchronization', () {
    // A JPEG starts with 0xFF 0xD8 0xFF 0xE0, and 0xFF 0xE0 looks like the
    // start of an MPEG frame.
    final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0, 0xFF, 0, 1, 0xFF]);

    test('ID3v2.4 unsynchronizes the frame that needs it and flags it',
        () async {
      final file = writeFile([
        ...id3Tag(4, [frame('TIT2', utf8Text('t'), 4)]),
        ...audio,
      ]);

      final handler = ID3Handler(file.path);
      handler.addMetadata({'picture': jpeg});
      await handler.applyMetadataChanges();

      final bytes = file.readAsBytesSync();
      final tag = readTag(bytes);
      // No false sync anywhere in the tag.
      expect(hasFalseSync(bytes.sublist(0, tag.audioStart)), isFalse);
      // Only the picture frame is flagged, not the title; the tag flag is off.
      expect(tag.flags & 0x80, 0);
      final apic = bytes.indexOfSequence(ascii.encode('APIC'));
      expect(bytes[apic + 9] & 0x02, 0x02);
      final tit2 = bytes.indexOfSequence(ascii.encode('TIT2'));
      expect(bytes[tit2 + 9] & 0x02, 0);

      final picture = ID3Handler(file.path).getMetadata<Map>('picture')!;
      expect(picture['data'], jpeg);
      expect(bytes.sublist(tag.audioStart), audio);
    });

    test('ID3v2.3 unsynchronizes the whole tag and sets the tag flag',
        () async {
      final file = writeFile([
        ...id3Tag(3, [frame('TIT2', latin1Text('t'), 3)]),
        ...audio,
      ]);

      final handler = ID3Handler(file.path);
      handler.addMetadata({'picture': jpeg});
      await handler.applyMetadataChanges();

      final bytes = file.readAsBytesSync();
      final tag = readTag(bytes);
      expect(tag.version, 3);
      expect(tag.flags & 0x80, 0x80);
      expect(hasFalseSync(bytes.sublist(0, tag.audioStart)), isFalse);

      final reread = ID3Handler(file.path);
      expect(reread.getMetadata<Map>('picture')!['data'], jpeg);
      expect(reread.getMetadata<String>('title'), 't');
      expect(bytes.sublist(tag.audioStart), audio);
    });

    test('a tag without false syncs is not unsynchronized', () async {
      final file = writeFile([
        ...id3Tag(3, [frame('TIT2', latin1Text('t'), 3)]),
        ...audio,
      ]);

      final handler = ID3Handler(file.path);
      handler.updateMetadata({'title': 'plain'});
      await handler.applyMetadataChanges();

      expect(readTag(file.readAsBytesSync()).flags, 0);
    });

    test('reads an unsynchronized ID3v2.4 frame and keeps it when rewriting',
        () async {
      final body = [0, ...ascii.encode('image/jpeg'), 0, 3, 0, ...jpeg];
      // What a tagger would write: a 0x00 after every 0xFF that needs one.
      final unsynced = <int>[];
      for (var i = 0; i < body.length; i++) {
        unsynced.add(body[i]);
        if (body[i] == 0xFF &&
            (i + 1 == body.length || body[i + 1] == 0 || body[i + 1] >= 0xE0)) {
          unsynced.add(0);
        }
      }
      final file = writeFile([
        ...id3Tag(4, [
          frame('APIC', unsynced, 4, flags: 0x0002),
          frame('TIT2', utf8Text('Old title'), 4),
        ]),
        ...audio,
      ]);

      final handler = ID3Handler(file.path);
      expect(handler.getMetadata<Map>('picture')!['data'], jpeg);

      handler.updateMetadata({'title': 'New title'});
      await handler.applyMetadataChanges();

      final reread = ID3Handler(file.path);
      expect(reread.getMetadata<String>('title'), 'New title');
      expect(reread.getMetadata<Map>('picture')!['data'], jpeg);
      expect(readTag(file.readAsBytesSync()).frames['APIC']!.single, body);
    });

    test('reads a tag that is unsynchronized as a whole in ID3v2.4', () async {
      // The flag in the header says every frame is unsynchronized.
      final title = utf8Text('t');
      final apicBody = [0, ...ascii.encode('image/jpeg'), 0, 3, 0, ...jpeg];
      final unsynced = <int>[];
      for (var i = 0; i < apicBody.length; i++) {
        unsynced.add(apicBody[i]);
        if (apicBody[i] == 0xFF &&
            (i + 1 == apicBody.length ||
                apicBody[i + 1] == 0 ||
                apicBody[i + 1] >= 0xE0)) {
          unsynced.add(0);
        }
      }
      final tag = id3Tag(4, [
        frame('TIT2', title, 4),
        frame('APIC', unsynced, 4),
      ]);
      tag[5] = 0x80;
      final file = writeFile([...tag, ...audio]);

      final handler = ID3Handler(file.path);
      expect(handler.getMetadata<Map>('picture')!['data'], jpeg);
      expect(handler.getMetadata<String>('title'), 't');

      // Rewriting keeps the picture readable even though the tag flag is gone.
      handler.updateMetadata({'title': 'u'});
      await handler.applyMetadataChanges();
      expect(
        ID3Handler(file.path).getMetadata<Map>('picture')!['data'],
        jpeg,
      );
    });
  });

  group('URL, synchronized lyrics and chapter frames', () {
    final lines = [
      {'timeStamp': 0, 'text': 'First line'},
      {'timeStamp': 1500, 'text': 'Second line'},
      // A time stamp with zero bytes in it, after text that is not terminated
      // by the time stamp.
      {'timeStamp': 0x01000100, 'text': 'Last'},
    ];

    test('a user defined URL is written, read and replaced by description',
        () async {
      final file = writeFile([
        ...id3Tag(4, [frame('TIT2', utf8Text('t'), 4)]),
        ...audio,
      ]);

      final handler = ID3Handler(file.path);
      handler.addMetadata({
        'WXXX:Bandcamp': 'https://band.example/album',
      });
      await handler.applyMetadataChanges();

      final second = ID3Handler(file.path);
      second.addMetadata({
        'userDefinedUrl': {'description': 'Shop', 'url': 'https://shop.example'},
      });
      second.updateMetadata({'WXXX:Bandcamp': 'https://band.example/new'});
      await second.applyMetadataChanges();

      final frames = readTag(file.readAsBytesSync()).frames['WXXX']!;
      expect(frames, hasLength(2));
      final texts = frames.map((f) => utf8.decode(f.sublist(1))).toList();
      expect(texts, contains('Bandcamp\u0000https://band.example/new'));
      expect(texts, contains('Shop\u0000https://shop.example'));
      expect(
        ID3Handler(file.path).getMetadata<Map>('userDefinedUrl'),
        {'description': 'Shop', 'url': 'https://shop.example'},
      );
    });

    test('synchronized lyrics are written and read back', () async {
      final file = writeFile([
        ...id3Tag(4, [frame('TIT2', utf8Text('t'), 4)]),
        ...audio,
      ]);

      final handler = ID3Handler(file.path);
      handler.addMetadata({
        'synchronizedLyrics': {
          'language': 'eng',
          'description': 'Karaoke',
          'lyrics': lines,
        },
      });
      await handler.applyMetadataChanges();

      final lyrics = ID3Handler(file.path).getMetadata<Map>('synchronizedLyrics')!;
      expect(lyrics['language'], 'eng');
      expect(lyrics['description'], 'Karaoke');
      expect(lyrics['timeStampFormat'], 2);
      expect(lyrics['contentType'], 1);
      expect(lyrics['lyrics'], lines);
    });

    test('synchronized lyrics in ID3v2.3 are written as UTF-16', () async {
      final file = writeFile([
        ...id3Tag(3, [frame('TIT2', latin1Text('t'), 3)]),
        ...audio,
      ]);

      final handler = ID3Handler(file.path);
      handler.addMetadata({
        'synchronizedLyrics': {
          'description': 'Lyrics',
          'lyrics': [
            {'timeStamp': 10, 'text': 'Gr\u00fc\u00dfe \u2603'},
            {'timeStamp': 20, 'text': 'Done'},
          ],
        },
      });
      await handler.applyMetadataChanges();

      expect(readTag(file.readAsBytesSync()).version, 3);
      final lyrics = ID3Handler(file.path).getMetadata<Map>('synchronizedLyrics')!;
      expect(lyrics['description'], 'Lyrics');
      expect(lyrics['lyrics'], [
        {'timeStamp': 10, 'text': 'Gr\u00fc\u00dfe \u2603'},
        {'timeStamp': 20, 'text': 'Done'},
      ]);
    });

    test('invalid synchronized lyrics throw and change nothing', () async {
      final file = writeFile([
        ...id3Tag(4, [frame('TIT2', utf8Text('t'), 4)]),
        ...audio,
      ]);
      final before = file.readAsBytesSync();

      for (final bad in <dynamic>[
        'just text',
        {'lyrics': []},
        {
          'lyrics': [
            {'timeStamp': -1, 'text': 'x'},
          ],
        },
        {
          'timeStampFormat': 3,
          'lyrics': [
            {'timeStamp': 1, 'text': 'x'},
          ],
        },
        {
          'language': 'english',
          'lyrics': [
            {'timeStamp': 1, 'text': 'x'},
          ],
        },
      ]) {
        final handler = ID3Handler(file.path);
        handler.updateMetadata({'synchronizedLyrics': bad});
        await expectLater(
          handler.applyMetadataChanges(),
          throwsA(isA<ID3Exception>()),
          reason: '$bad',
        );
      }
      expect(file.readAsBytesSync(), before);
    });

    test('a chapter is written and read, and its title is not the track title',
        () async {
      final file = writeFile([
        ...id3Tag(4, [frame('TIT2', utf8Text('Track title'), 4)]),
        ...audio,
      ]);

      final handler = ID3Handler(file.path);
      handler.addMetadata({
        'chapter_ch1': {
          'startTime': 0,
          'endTime': 60000,
          'title': 'Introduction',
        },
        'chapter_ch2': {
          'startTime': 60000,
          'endTime': 120000,
          'subFrames': {'TIT2': 'Main part', 'TIT3': 'Subtitle'},
        },
        'tableOfContents_toc': {
          'isOrdered': true,
          'isTopLevel': true,
          'children': ['ch1', 'ch2'],
          'title': 'Contents',
        },
      });
      await handler.applyMetadataChanges();

      final reread = ID3Handler(file.path);
      expect(reread.getMetadata<String>('title'), 'Track title');

      final first = reread.getMetadata<Map>('chapter_ch1')!;
      expect(first['elementId'], 'ch1');
      expect(first['startTime'], 0);
      expect(first['endTime'], 60000);
      expect(first['startOffset'], 0xFFFFFFFF);
      expect(first['title'], 'Introduction');

      final second = reread.getMetadata<Map>('chapter_ch2')!;
      expect(second['subFrames'], {'TIT2': 'Main part', 'TIT3': 'Subtitle'});

      final toc = reread.getMetadata<Map>('tableOfContents_toc')!;
      expect(toc['children'], ['ch1', 'ch2']);
      expect(toc['isOrdered'], isTrue);
      expect(toc['isTopLevel'], isTrue);
      expect(toc['title'], 'Contents');
    });

    test('setting a chapter replaces only that chapter, removing works',
        () async {
      final file = writeFile([
        ...id3Tag(3, [frame('TIT2', latin1Text('t'), 3)]),
        ...audio,
      ]);

      final first = ID3Handler(file.path);
      first.addMetadata({
        'chapter_a': {'endTime': 1000, 'title': 'A'},
        'chapter_b': {'startTime': 1000, 'endTime': 2000, 'title': 'B'},
      });
      await first.applyMetadataChanges();

      final second = ID3Handler(file.path);
      second.updateMetadata({
        'chapter_a': {'endTime': 1500, 'title': 'A again'},
      });
      await second.applyMetadataChanges();

      var reread = ID3Handler(file.path);
      expect(reread.getMetadata<Map>('chapter_a')!['title'], 'A again');
      expect(reread.getMetadata<Map>('chapter_a')!['endTime'], 1500);
      expect(reread.getMetadata<Map>('chapter_b')!['title'], 'B');
      expect(readTag(file.readAsBytesSync()).frames['CHAP'], hasLength(2));

      final third = ID3Handler(file.path);
      third.removeMetadata(['chapter_b']);
      await third.applyMetadataChanges();

      reread = ID3Handler(file.path);
      expect(reread.metadata.contains('chapter_b'), isFalse);
      expect(reread.getMetadata<Map>('chapter_a')!['title'], 'A again');
    });

    test('an invalid chapter throws and changes nothing', () async {
      final file = writeFile([
        ...id3Tag(4, [frame('TIT2', utf8Text('t'), 4)]),
        ...audio,
      ]);
      final before = file.readAsBytesSync();

      for (final bad in <Map<String, dynamic>>[
        {'chapter_x': 'not a map'},
        {'chapter_x': {'startTime': -5}},
        {'chapter_x': {'endTime': 1 << 40}},
        {'chapter_x': {'subFrames': {'TXXX': 'nope'}}},
        {'chapter_x': {'title': 12}},
        {'tableOfContents_x': {'children': [1]}},
      ]) {
        final handler = ID3Handler(file.path);
        handler.updateMetadata(bad);
        await expectLater(
          handler.applyMetadataChanges(),
          throwsA(isA<ID3Exception>()),
          reason: '$bad',
        );
      }
      expect(file.readAsBytesSync(), before);
    });
  });

  group('without blocking', () {
    test('readMetadata gives what the handler has, read in another isolate',
        () async {
      final file = writeFile([
        ...id3Tag(4, [
          frame('TIT2', utf8Text('Some title'), 4),
          frame('TPE1', utf8Text('Some artist'), 4),
        ]),
        ...audio,
      ]);

      final metadata = await ID3Handler.readMetadata(file.path);

      expect(metadata.asMap(), ID3Handler(file.path).metadata.asMap());
      expect(metadata.get<String>('title'), 'Some title');
    });

    test('operations queued while the file is being written stay queued',
        () async {
      final file = writeFile([
        ...id3Tag(4, [frame('TIT2', utf8Text('Old title'), 4)]),
        ...audio,
      ]);

      final handler = ID3Handler(file.path);
      handler.updateMetadata({'title': 'First'});
      final applying = handler.applyMetadataChanges(inPlace: false);
      handler.updateMetadata({'artist': 'Queued meanwhile'});
      await applying;

      expect(handler.pendingOperations, hasLength(1));
      expect(handler.pendingOperations.single.key, 'artist');
      await handler.applyMetadataChanges();
      expect(
        ID3Handler(file.path).getMetadata<String>('artist'),
        'Queued meanwhile',
      );
      expect(ID3Handler(file.path).getMetadata<String>('title'), 'First');
    });
  });

  group('duration', () {
    // MPEG-1 layer III, 128 kbps, 44.1 kHz, stereo: 417 bytes per frame.
    List<int> mp3Frame({List<int> inside = const []}) {
      final frame = List<int>.filled(417, 0);
      frame.setRange(0, 4, [0xFF, 0xFB, 0x90, 0x00]);
      frame.setRange(36, 36 + inside.length, inside);
      return frame;
    }

    test('of a constant bitrate file comes from its size and bitrate', () {
      final file = writeFile([
        ...id3Tag(3, [frame('TIT2', latin1Text('t'), 3)], padding: 50),
        for (var i = 0; i < 100; i++) ...mp3Frame(),
      ]);

      // 100 frames of 417 bytes at 128 kbps.
      expect(
        ID3Handler(file.path).getMetadata<int>('duration'),
        closeTo(100 * 417 * 8 / 128, 1),
      );
    });

    test('does not count an ID3v1 tag as audio', () {
      final file = writeFile([
        ...id3Tag(3, [frame('TIT2', latin1Text('t'), 3)]),
        for (var i = 0; i < 100; i++) ...mp3Frame(),
        ...id3v1Tag(),
      ]);

      expect(
        ID3Handler(file.path).getMetadata<int>('duration'),
        closeTo(100 * 417 * 8 / 128, 1),
      );
    });

    test('of a file with a Xing header comes from the frame count', () {
      final xing = [
        ...ascii.encode('Xing'), 0, 0, 0, 1, // flags: frame count present
        ...uint32be(250),
      ];
      final file = writeFile([
        ...mp3Frame(inside: xing),
        for (var i = 0; i < 10; i++) ...mp3Frame(),
      ]);

      // 250 frames of 1152 samples at 44.1 kHz.
      expect(
        ID3Handler(file.path).getMetadata<int>('duration'),
        (250 * 1152 * 1000 / 44100).round(),
      );
    });

    test('of an MPEG-2 layer III file uses 576 samples per frame', () {
      // MPEG-2 layer III, 64 kbps, 22.05 kHz, mono: 208 bytes per frame.
      List<int> frame2() {
        final frame = List<int>.filled(208, 0);
        frame.setRange(0, 4, [0xFF, 0xF3, 0x80, 0xC0]);
        return frame;
      }

      final file = writeFile([
        for (var i = 0; i < 20; i++) ...frame2(),
      ]);

      expect(
        ID3Handler(file.path).getMetadata<int>('duration'),
        closeTo(20 * 208 * 8 / 64, 1),
      );
    });

    test('is not set for a file without audio frames', () {
      final file = writeFile(audio);

      expect(ID3Handler(file.path).metadata.contains('duration'), isFalse);
    });
  });

  group('ID3v1', () {
    test('only fills in what the ID3v2 tag does not have', () {
      final longTitle = 'A title that is longer than thirty characters';
      final file = writeFile([
        ...id3Tag(4, [
          frame('TIT2', utf8Text(longTitle), 4),
          frame('TPE1', utf8Text('V2 artist'), 4),
        ]),
        ...audio,
        ...id3v1Tag(), // title 'Old v1', artist 'Old artist', album 'Old album'
      ]);

      final handler = ID3Handler(file.path);
      expect(handler.getMetadata<String>('title'), longTitle);
      expect(handler.getMetadata<String>('artist'), 'V2 artist');
      expect(handler.getMetadata<String>('album'), 'Old album');
      expect(handler.getMetadata<int>('track'), 4);
    });

    test('empty ID3v1 fields do not replace anything', () {
      final v1 = id3v1Tag()
        ..fillRange(3, 33, 0) // title
        ..[127] = 255; // genre
      final file = writeFile([
        ...id3Tag(4, [
          frame('TIT2', utf8Text('V2 title'), 4),
          frame('TCON', utf8Text('Jazz'), 4),
        ]),
        ...audio,
        ...v1,
      ]);

      final handler = ID3Handler(file.path);
      expect(handler.getMetadata<String>('title'), 'V2 title');
      expect(handler.getMetadata<String>('genre'), 'Jazz');
    });

    test('no genre and no title mean no keys', () {
      final v1 = id3v1Tag()
        ..fillRange(3, 33, 0)
        ..[127] = 255;
      final file = writeFile([...audio, ...v1]);

      final handler = ID3Handler(file.path);
      expect(handler.metadata.contains('title'), isFalse);
      expect(handler.metadata.contains('genre'), isFalse);
    });

    test('a file shorter than an ID3v1 tag is not a problem', () {
      final file = writeFile([1, 2, 3, 4, 5]);

      expect(ID3Handler(file.path).metadata.contains('title'), isFalse);
    });
  });

  group('Metadata', () {
    test('get returns null for a value of another type instead of throwing',
        () {
      final metadata = Metadata()..set('genre', ['Rock', 'Pop']);

      expect(metadata.get<String>('genre'), isNull);
      expect(metadata.get<List<String>>('genre'), ['Rock', 'Pop']);
      expect(metadata.get<String>('missing'), isNull);
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
      handler.updateMetadata({'bpm': {'not': 'text'}});

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

extension on Uint8List {
  /// The index of the first occurrence of [pattern], or -1.
  int indexOfSequence(List<int> pattern) {
    for (var i = 0; i + pattern.length <= length; i++) {
      var match = true;
      for (var j = 0; j < pattern.length; j++) {
        if (this[i + j] != pattern[j]) {
          match = false;
          break;
        }
      }
      if (match) return i;
    }
    return -1;
  }
}
