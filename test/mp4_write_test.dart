import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:logger/logger.dart';
import 'package:mpeg_codec/mpeg_codec.dart';
import 'package:test/test.dart';

List<int> uint32(int value) => [
  (value >> 24) & 0xFF,
  (value >> 16) & 0xFF,
  (value >> 8) & 0xFF,
  value & 0xFF,
];

List<int> box(String type, List<int> payload) => [
  ...uint32(8 + payload.length),
  ...latin1.encode(type),
  ...payload,
];

/// A box with a 64-bit size.
List<int> largeBox(String type, List<int> payload) => [
  ...uint32(1),
  ...latin1.encode(type),
  ...uint32(0),
  ...uint32(16 + payload.length),
  ...payload,
];

/// An `ilst` item holding one `data` atom of the given type.
List<int> item(String name, int dataType, List<int> value) =>
    box(name, box('data', [0, 0, 0, dataType, 0, 0, 0, 0, ...value]));

List<int> textItem(String name, String text) =>
    item(name, 1, utf8.encode(text));

/// A freeform ('----') item, as iTunes writes for custom tags.
List<int> freeformItem(String mean, String name, String value) => box('----', [
  ...box('mean', [0, 0, 0, 0, ...utf8.encode(mean)]),
  ...box('name', [0, 0, 0, 0, ...utf8.encode(name)]),
  ...box('data', [0, 0, 0, 1, 0, 0, 0, 0, ...utf8.encode(value)]),
]);

const chunkLength = 1000;

/// Three chunks of recognisable media data.
final Uint8List media = Uint8List.fromList(
  List.generate(3 * chunkLength, (i) => (i ~/ chunkLength) * 60 + i % 50),
);

List<int> moovBox({
  required List<int> chunkOffsets,
  List<int>? ilstItems,
  bool withUdta = true,
  List<int> udtaTrailer = const [],
  List<int> metaTrailer = const [],
}) {
  final stco = box('stco', [
    0, 0, 0, 0, // version and flags
    ...uint32(chunkOffsets.length),
    for (final offset in chunkOffsets) ...uint32(offset),
  ]);
  final trak = box('trak', [
    ...box('tkhd', List.filled(84, 0)),
    ...box('mdia', [
      ...box('mdhd', List.filled(24, 0)),
      ...box('minf', [
        ...box('stbl', [...box('stsd', List.filled(8, 0)), ...stco]),
      ]),
    ]),
  ]);
  final mvhd = box('mvhd', [
    ...List.filled(12, 0),
    ...uint32(1000),
    ...uint32(5000),
    ...List.filled(80, 0),
  ]);
  final udta = box('udta', [
    ...box('meta', [
      0, 0, 0, 0, // version and flags
      ...box('hdlr', [
        ...List.filled(8, 0),
        ...latin1.encode('mdirappl'),
        ...List.filled(9, 0),
      ]),
      ...box('ilst', ilstItems ?? []),
      ...metaTrailer,
    ]),
    ...udtaTrailer,
  ]);
  return box('moov', [...mvhd, ...trak, if (withUdta) ...udta]);
}

List<int> ftypBox() => box('ftyp', [
  ...latin1.encode('M4A '),
  0,
  0,
  0,
  0,
  ...latin1.encode('M4A mp42isom'),
]);

/// Builds an m4a file. With [moovFirst] the layout is ftyp, moov, free, mdat
/// (like most iTunes files), otherwise ftyp, mdat, moov.
Uint8List buildM4a({
  bool moovFirst = true,
  List<int>? ilstItems,
  bool withUdta = true,
  bool largeMdat = false,
  List<int> extraBoxes = const [],
  List<int> udtaTrailer = const [],
  List<int> metaTrailer = const [],
  List<int> fileTrailer = const [],
}) {
  final ftyp = ftypBox();
  final free = box('free', List.filled(40, 0));
  final mdatHeader = largeMdat ? 16 : 8;
  final mdat = largeMdat ? largeBox('mdat', media) : box('mdat', media);

  List<int> moov(int mediaStart) => moovBox(
    chunkOffsets: [for (var i = 0; i < 3; i++) mediaStart + i * chunkLength],
    ilstItems: ilstItems,
    withUdta: withUdta,
    udtaTrailer: udtaTrailer,
    metaTrailer: metaTrailer,
  );

  if (moovFirst) {
    final moovLength = moov(0).length;
    final start =
        ftyp.length + moovLength + extraBoxes.length + free.length + mdatHeader;
    return Uint8List.fromList([
      ...ftyp,
      ...moov(start),
      ...extraBoxes,
      ...free,
      ...mdat,
      ...fileTrailer,
    ]);
  }

  final start = ftyp.length + mdatHeader;
  return Uint8List.fromList([...ftyp, ...mdat, ...moov(start), ...fileTrailer]);
}

/// A fragmented file: ftyp, sidx, moov, moof, mdat, mfra. The offsets that
/// point into the file are the first offset of the sidx (which counts from the
/// end of the sidx), the base data offset in the tfhd, the moof offset in the
/// tfra, and the chunk offsets.
Uint8List buildFragmented({required List<int> ilstItems}) {
  final ftyp = ftypBox();
  const sidxLength = 8 + 36;
  final moovLength = moovBox(
    chunkOffsets: [0, 0, 0],
    ilstItems: ilstItems,
  ).length;
  final moofStart = ftyp.length + sidxLength + moovLength;

  final moof = box('moof', [
    ...box('mfhd', [0, 0, 0, 0, 0, 0, 0, 1]),
    ...box(
      'traf',
      box('tfhd', [
        0, 0, 0, 1, // version, flags: has a base data offset
        ...uint32(1), // track ID
        ...uint32(0), ...uint32(moofStart), // base data offset
      ]),
    ),
  ]);
  final mdatStart = moofStart + moof.length + 8;

  final sidx = box('sidx', [
    0, 0, 0, 0, // version and flags
    ...uint32(1), // reference ID
    ...uint32(1000), // timescale
    ...uint32(0), // earliest presentation time
    ...uint32(moovLength), // first offset: from the end of the sidx to the moof
    0, 0, 0, 1, // reserved, one reference
    ...uint32(moof.length + 8 + media.length),
    ...uint32(1000),
    ...uint32(0x90000000),
  ]);
  expect(sidx.length, sidxLength);

  final tfra = box('tfra', [
    0, 0, 0, 0, // version and flags
    ...uint32(1), // track ID
    ...uint32(0), // one byte each for the traf, trun and sample numbers
    ...uint32(1), // one entry
    ...uint32(0), ...uint32(moofStart), 1, 1, 1,
  ]);
  final mfraLength = 8 + tfra.length + 16;
  final mfra = box('mfra', [
    ...tfra,
    ...box('mfro', [0, 0, 0, 0, ...uint32(mfraLength)]),
  ]);

  return Uint8List.fromList([
    ...ftyp,
    ...sidx,
    ...moovBox(
      chunkOffsets: [for (var i = 0; i < 3; i++) mdatStart + i * chunkLength],
      ilstItems: ilstItems,
    ),
    ...moof,
    ...box('mdat', media),
    ...mfra,
  ]);
}

/// Where each top-level box starts, by type.
Map<String, int> boxStarts(Uint8List bytes) {
  final view = ByteData.sublistView(bytes);
  final starts = <String, int>{};
  var position = 0;
  while (position < bytes.length) {
    var size = view.getUint32(position);
    if (size == 1) size = view.getUint64(position + 8);
    starts.putIfAbsent(
      latin1.decode(bytes.sublist(position + 4, position + 8)),
      () => position,
    );
    position += size;
  }
  return starts;
}

/// The payload range of the box at [path] below [start, end), or null.
({int start, int end})? findBox(
  Uint8List bytes,
  List<String> path, [
  int start = 0,
  int? end,
]) {
  end ??= bytes.length;
  final view = ByteData.sublistView(bytes);
  var position = start;
  while (position + 8 <= end) {
    var size = view.getUint32(position);
    var header = 8;
    if (size == 1) {
      size = view.getUint64(position + 8);
      header = 16;
    }
    final type = latin1.decode(bytes.sublist(position + 4, position + 8));
    if (type == path.first) {
      var payload = position + header;
      if (type == 'meta') payload += 4;
      if (path.length == 1) return (start: payload, end: position + size);
      final found = findBox(bytes, path.sublist(1), payload, position + size);
      if (found != null) return found;
    }
    position += size;
  }
  return null;
}

/// Size of every top-level box, which must tile the file exactly.
List<String> topLevelTypes(Uint8List bytes) {
  final view = ByteData.sublistView(bytes);
  final types = <String>[];
  var position = 0;
  while (position < bytes.length) {
    var size = view.getUint32(position);
    if (size == 1) size = view.getUint64(position + 8);
    types.add(latin1.decode(bytes.sublist(position + 4, position + 8)));
    position += size;
  }
  expect(
    position,
    bytes.length,
    reason: 'top-level boxes do not fill the file',
  );
  return types;
}

List<int> chunkOffsetsOf(Uint8List bytes) {
  final stco = findBox(bytes, [
    'moov',
    'trak',
    'mdia',
    'minf',
    'stbl',
    'stco',
  ])!;
  final view = ByteData.sublistView(bytes);
  final count = view.getUint32(stco.start + 4);
  return [
    for (var i = 0; i < count; i++) view.getUint32(stco.start + 8 + i * 4),
  ];
}

/// Checks that every chunk offset in [bytes] still points at its media.
void expectChunksIntact(Uint8List bytes) {
  final offsets = chunkOffsetsOf(bytes);
  expect(offsets, hasLength(3));
  for (var i = 0; i < 3; i++) {
    expect(
      bytes.sublist(offsets[i], offsets[i] + chunkLength),
      media.sublist(i * chunkLength, (i + 1) * chunkLength),
      reason: 'chunk $i is not at its offset',
    );
  }
}

void main() {
  late Directory dir;
  var counter = 0;

  setUpAll(() => Logger.level = Level.off);

  setUp(() => dir = Directory.systemTemp.createTempSync('mp4_write_test_'));

  tearDown(() => dir.deleteSync(recursive: true));

  File writeFile(List<int> bytes) {
    final file = File('${dir.path}/song${counter++}.m4a');
    file.writeAsBytesSync(bytes);
    return file;
  }

  final tagged = [
    ...textItem('©nam', 'Old title'),
    ...textItem('©ART', 'Some artist'),
    ...textItem('©alb', 'Some album'),
  ];

  group('chunk offsets', () {
    test('are moved with the media when moov comes first and grows', () async {
      final file = writeFile(buildM4a(ilstItems: tagged));
      expectChunksIntact(file.readAsBytesSync());
      final before = chunkOffsetsOf(file.readAsBytesSync());

      final handler = MP4Handler(file.path);
      handler.updateMetadata({
        'title': 'A much longer title than the one that was there before',
      });
      await handler.applyMetadataChanges();

      final bytes = file.readAsBytesSync();
      expect(topLevelTypes(bytes), ['ftyp', 'moov', 'free', 'mdat']);
      expect(chunkOffsetsOf(bytes), isNot(before));
      expectChunksIntact(bytes);
      expect(
        MP4Handler(file.path).getMetadata<String>('title'),
        'A much longer title than the one that was there before',
      );
    });

    test('are moved when moov comes first and there is no room left', () async {
      final file = writeFile(buildM4a(ilstItems: tagged));
      final before = chunkOffsetsOf(file.readAsBytesSync());

      final handler = MP4Handler(file.path);
      handler.updateMetadata({'title': 'x' * 100});
      await handler.applyMetadataChanges(inPlace: false);

      final bytes = file.readAsBytesSync();
      expect(chunkOffsetsOf(bytes), isNot(before));
      expectChunksIntact(bytes);
      expect(topLevelTypes(bytes), ['ftyp', 'moov', 'free', 'mdat']);
    });

    test('stay as they were when mdat comes first', () async {
      final file = writeFile(buildM4a(moovFirst: false, ilstItems: tagged));
      final before = chunkOffsetsOf(file.readAsBytesSync());

      final handler = MP4Handler(file.path);
      handler.updateMetadata({'title': 'A much longer title than before!'});
      await handler.applyMetadataChanges();

      final bytes = file.readAsBytesSync();
      expect(topLevelTypes(bytes), ['ftyp', 'mdat', 'moov']);
      expect(chunkOffsetsOf(bytes), before);
      expectChunksIntact(bytes);
    });

    test('work with a 64-bit mdat header', () async {
      final file = writeFile(buildM4a(ilstItems: tagged, largeMdat: true));
      expectChunksIntact(file.readAsBytesSync());

      final handler = MP4Handler(file.path);
      handler.updateMetadata({'title': 'A much longer title than before!'});
      await handler.applyMetadataChanges();

      final bytes = file.readAsBytesSync();
      expect(topLevelTypes(bytes), ['ftyp', 'moov', 'free', 'mdat']);
      expectChunksIntact(bytes);
      // Still written with the 16-byte header.
      final mdat = findBox(bytes, ['mdat'])!;
      expect(ByteData.sublistView(bytes).getUint32(mdat.start - 16), 1);
    });
  });

  group('without blocking', () {
    test(
      'readMetadata gives what the handler has, read in another isolate',
      () async {
        final file = writeFile(buildM4a(ilstItems: tagged));

        final metadata = await MP4Handler.readMetadata(file.path);

        expect(metadata.asMap(), MP4Handler(file.path).metadata.asMap());
        expect(metadata.get<String>('title'), 'Old title');
      },
    );

    test(
      'operations queued while the file is being written stay queued',
      () async {
        final file = writeFile(buildM4a(ilstItems: tagged));

        final handler = MP4Handler(file.path);
        handler.updateMetadata({'title': 'x' * 100});
        final applying = handler.applyMetadataChanges(inPlace: false);
        handler.updateMetadata({'album': 'Queued meanwhile'});
        await applying;

        expect(handler.pendingOperations, hasLength(1));
        await handler.applyMetadataChanges();
        final reread = MP4Handler(file.path);
        expect(reread.getMetadata<String>('album'), 'Queued meanwhile');
        expect(reread.getMetadata<String>('title'), 'x' * 100);
        expectChunksIntact(file.readAsBytesSync());
      },
    );
  });

  group('in place', () {
    final longTitle = 'A much longer title than the one that was there before';

    test('a change that fits in the free atom moves nothing', () async {
      final file = writeFile(buildM4a(ilstItems: tagged));
      final before = file.readAsBytesSync();

      final handler = MP4Handler(file.path);
      handler.updateMetadata({'title': 'Old title!'}); // a byte longer
      await handler.applyMetadataChanges();

      final bytes = file.readAsBytesSync();
      expect(bytes.length, before.length);
      expect(topLevelTypes(bytes), ['ftyp', 'moov', 'free', 'mdat']);
      // The media is where it was, and the offsets did not change.
      final mdat = findBox(bytes, ['mdat'])!;
      expect(bytes.sublist(mdat.start, mdat.end), media);
      expect(chunkOffsetsOf(bytes), chunkOffsetsOf(before));
      expectChunksIntact(bytes);
      expect(MP4Handler(file.path).getMetadata<String>('title'), 'Old title!');
      expect(File('${file.path}.tmp').existsSync(), isFalse);
    });

    test('a smaller moov leaves the space as padding', () async {
      final file = writeFile(buildM4a(ilstItems: tagged));
      final before = file.readAsBytesSync();

      final handler = MP4Handler(file.path);
      handler.removeMetadata(['artist', 'album']);
      await handler.applyMetadataChanges();

      final bytes = file.readAsBytesSync();
      expect(bytes.length, before.length);
      expect(topLevelTypes(bytes), ['ftyp', 'moov', 'free', 'mdat']);
      expect(chunkOffsetsOf(bytes), chunkOffsetsOf(before));
      expectChunksIntact(bytes);
    });

    test('gives the same file as writing a new one', () async {
      final original = buildM4a(ilstItems: tagged);
      final inPlace = writeFile(original);
      final copied = writeFile(original);

      for (final entry in {inPlace: true, copied: false}.entries) {
        final handler = MP4Handler(entry.key.path);
        handler.updateMetadata({'title': 'Old title!', 'year': '1999'});
        await handler.applyMetadataChanges(inPlace: entry.value);
      }

      expect(inPlace.readAsBytesSync(), copied.readAsBytesSync());
    });

    test(
      'a change that does not fit moves the media and leaves padding',
      () async {
        final file = writeFile(buildM4a(ilstItems: tagged));

        final handler = MP4Handler(file.path);
        handler.updateMetadata({'title': longTitle});
        await handler.applyMetadataChanges();

        final first = file.readAsBytesSync();
        expect(topLevelTypes(first), ['ftyp', 'moov', 'free', 'mdat']);
        expectChunksIntact(first);
        final free = boxStarts(first)['free']!;
        expect(
          ByteData.sublistView(first).getUint32(free),
          MP4Handler.freePadding,
        );

        // A second, small edit now fits, so nothing moves.
        final second = MP4Handler(file.path);
        second.updateMetadata({'album': 'Another album name'});
        await second.applyMetadataChanges();

        final again = file.readAsBytesSync();
        expect(again.length, first.length);
        expect(chunkOffsetsOf(again), chunkOffsetsOf(first));
        expectChunksIntact(again);
        expect(
          MP4Handler(file.path).getMetadata<String>('album'),
          'Another album name',
        );
      },
    );

    test(
      'a free atom inside meta takes the change, so moov keeps its size',
      () async {
        final file = writeFile(
          buildM4a(
            ilstItems: tagged,
            metaTrailer: box('free', List.filled(92, 0)),
          ),
        );
        final before = file.readAsBytesSync();
        final moovBefore = ByteData.sublistView(
          before,
        ).getUint32(boxStarts(before)['moov']!);

        final handler = MP4Handler(file.path);
        handler.updateMetadata({'title': longTitle});
        await handler.applyMetadataChanges();

        final bytes = file.readAsBytesSync();
        expect(bytes.length, before.length);
        expect(
          ByteData.sublistView(bytes).getUint32(boxStarts(bytes)['moov']!),
          moovBefore,
        );
        expect(chunkOffsetsOf(bytes), chunkOffsetsOf(before));
        expectChunksIntact(bytes);
        expect(MP4Handler(file.path).getMetadata<String>('title'), longTitle);

        // Removing it again gives the space back to the same free atom.
        final second = MP4Handler(file.path);
        second.updateMetadata({'title': 'Old title'});
        await second.applyMetadataChanges();
        expect(file.readAsBytesSync().length, before.length);
        expect(MP4Handler(file.path).getMetadata<String>('title'), 'Old title');
      },
    );

    test('moov at the end of the file grows and shrinks in place', () async {
      final original = buildM4a(moovFirst: false, ilstItems: tagged);
      final file = writeFile(original);
      final moovStart = boxStarts(original)['moov']!;

      final grow = MP4Handler(file.path);
      grow.updateMetadata({'title': longTitle});
      await grow.applyMetadataChanges();

      final grown = file.readAsBytesSync();
      expect(grown.length, greaterThan(original.length));
      expect(grown.sublist(0, moovStart), original.sublist(0, moovStart));
      expectChunksIntact(grown);

      final shrink = MP4Handler(file.path);
      shrink.removeMetadata(['title', 'artist', 'album']);
      await shrink.applyMetadataChanges();

      final shrunk = file.readAsBytesSync();
      expect(shrunk.length, lessThan(original.length));
      expect(shrunk.sublist(0, moovStart), original.sublist(0, moovStart));
      expect(topLevelTypes(shrunk), ['ftyp', 'mdat', 'moov']);
      expectChunksIntact(shrunk);
      expect(MP4Handler(file.path).metadata.contains('title'), isFalse);
    });

    test('bytes after the last atom move with moov at the end', () async {
      final trailer = [1, 2, 3];
      final file = writeFile(
        buildM4a(moovFirst: false, ilstItems: tagged, fileTrailer: trailer),
      );

      final handler = MP4Handler(file.path);
      handler.updateMetadata({'title': longTitle});
      await handler.applyMetadataChanges();

      final bytes = file.readAsBytesSync();
      expect(bytes.sublist(bytes.length - 3), trailer);
      expect(MP4Handler(file.path).getMetadata<String>('title'), longTitle);
    });
  });

  group('fragmented files', () {
    final longTitle = 'A much longer title than the one that was there before';

    void expectFragmentOffsets(Uint8List bytes) {
      final starts = boxStarts(bytes);
      final view = ByteData.sublistView(bytes);

      // sidx: the first offset still reaches the moof.
      final sidx = starts['sidx']!;
      final sidxEnd = sidx + view.getUint32(sidx);
      expect(sidxEnd + view.getUint32(sidx + 8 + 16), starts['moof']);

      // tfhd: the base data offset is the moof.
      final tfhd = findBox(bytes, ['moof', 'traf', 'tfhd'])!;
      expect(view.getUint64(tfhd.start + 8), starts['moof']);

      // tfra: the moof offset.
      final tfra = findBox(bytes, ['mfra', 'tfra'])!;
      expect(view.getUint32(tfra.start + 16 + 4), starts['moof']);

      expectChunksIntact(bytes);
    }

    test('are written with every offset moved when moov grows', () async {
      final original = buildFragmented(ilstItems: tagged);
      final file = writeFile(original);
      expectFragmentOffsets(original);

      final handler = MP4Handler(file.path);
      handler.updateMetadata({'title': longTitle});
      await handler.applyMetadataChanges();

      final bytes = file.readAsBytesSync();
      expect(topLevelTypes(bytes), [
        'ftyp',
        'sidx',
        'moov',
        'free',
        'moof',
        'mdat',
        'mfra',
      ]);
      expect(bytes.length, greaterThan(original.length));
      expectFragmentOffsets(bytes);
      expect(MP4Handler(file.path).getMetadata<String>('title'), longTitle);
    });

    test('are written with every offset moved when moov shrinks', () async {
      final original = buildFragmented(ilstItems: tagged);
      final file = writeFile(original);

      final handler = MP4Handler(file.path);
      handler.removeMetadata(['artist', 'album']);
      await handler.applyMetadataChanges();

      final bytes = file.readAsBytesSync();
      expectFragmentOffsets(bytes);
      expect(MP4Handler(file.path).metadata.contains('album'), isFalse);
    });
  });

  group('structure', () {
    test('creates udta, meta and ilst when the file has none', () async {
      final file = writeFile(buildM4a(withUdta: false));
      expect(MP4Handler(file.path).metadata.contains('title'), isFalse);

      final handler = MP4Handler(file.path);
      handler.addMetadata({'title': 'First tag', 'artist': 'Someone'});
      await handler.applyMetadataChanges();

      final bytes = file.readAsBytesSync();
      expect(findBox(bytes, ['moov', 'udta', 'meta', 'hdlr']), isNotNull);
      expect(findBox(bytes, ['moov', 'udta', 'meta', 'ilst']), isNotNull);
      expectChunksIntact(bytes);

      final reread = MP4Handler(file.path);
      expect(reread.getMetadata<String>('title'), 'First tag');
      expect(reread.getMetadata<String>('artist'), 'Someone');
    });

    test(
      'replaces every item with the same name and keeps the order',
      () async {
        final file = writeFile(
          buildM4a(
            ilstItems: [
              ...textItem('©nam', 'one'),
              ...textItem('©ART', 'artist'),
              ...textItem('©nam', 'two'),
              ...textItem('©alb', 'album'),
            ],
          ),
        );

        final handler = MP4Handler(file.path);
        handler.updateMetadata({'title': 'only'});
        await handler.applyMetadataChanges();

        final bytes = file.readAsBytesSync();
        final ilst = findBox(bytes, ['moov', 'udta', 'meta', 'ilst'])!;
        final names = <String>[];
        var position = ilst.start;
        final view = ByteData.sublistView(bytes);
        while (position < ilst.end) {
          names.add(latin1.decode(bytes.sublist(position + 4, position + 8)));
          position += view.getUint32(position);
        }
        expect(names, ['©nam', '©ART', '©alb']);
        expect(MP4Handler(file.path).getMetadata<String>('title'), 'only');
      },
    );

    test('removes a key from the file and from the metadata', () async {
      final file = writeFile(buildM4a(ilstItems: tagged));

      final handler = MP4Handler(file.path);
      expect(handler.metadata.contains('artist'), isTrue);
      handler.removeMetadata(['artist']);
      await handler.applyMetadataChanges();

      expect(handler.metadata.contains('artist'), isFalse);
      expect(handler.getMetadata<String>('title'), 'Old title');
      expect(MP4Handler(file.path).metadata.contains('artist'), isFalse);
    });

    test('keeps the other atoms of the file', () async {
      final file = writeFile(buildM4a(ilstItems: tagged));
      final before = file.readAsBytesSync();

      final handler = MP4Handler(file.path);
      handler.updateMetadata({'title': 'New title'});
      await handler.applyMetadataChanges();

      final after = file.readAsBytesSync();
      for (final path in [
        ['ftyp'],
        ['free'],
        ['moov', 'mvhd'],
        ['moov', 'trak', 'tkhd'],
        ['moov', 'udta', 'meta', 'hdlr'],
      ]) {
        final a = findBox(before, path)!;
        final b = findBox(after, path)!;
        expect(
          after.sublist(b.start, b.end),
          before.sublist(a.start, a.end),
          reason: path.join('/'),
        );
      }
    });
  });

  group('bytes that are not atoms', () {
    test('keeps the zero terminator at the end of udta', () async {
      final file = writeFile(
        buildM4a(ilstItems: tagged, udtaTrailer: [0, 0, 0, 0]),
      );

      final handler = MP4Handler(file.path);
      expect(handler.getMetadata<String>('title'), 'Old title');
      handler.updateMetadata({'title': 'A much longer title than before!'});
      await handler.applyMetadataChanges();

      final bytes = file.readAsBytesSync();
      final udta = findBox(bytes, ['moov', 'udta'])!;
      expect(bytes.sublist(udta.end - 4, udta.end), [0, 0, 0, 0]);
      expect(topLevelTypes(bytes), ['ftyp', 'moov', 'free', 'mdat']);
      expectChunksIntact(bytes);
      expect(
        MP4Handler(file.path).getMetadata<String>('title'),
        'A much longer title than before!',
      );
    });

    test('keeps bytes after the last atom', () async {
      final file = writeFile(
        buildM4a(ilstItems: tagged, fileTrailer: [1, 2, 3]),
      );

      final handler = MP4Handler(file.path);
      handler.updateMetadata({'title': 'A much longer title than before!'});
      await handler.applyMetadataChanges();

      final bytes = file.readAsBytesSync();
      expect(bytes.sublist(bytes.length - 3), [1, 2, 3]);
      expectChunksIntact(bytes);
    });
  });

  group('freeform atoms', () {
    final custom = [
      ...textItem('©nam', 'Title'),
      ...freeformItem('com.apple.iTunes', 'MOOD', 'calm'),
      ...freeformItem('com.apple.iTunes', 'SOURCE', 'vinyl'),
    ];

    test('are read with a mean.name key', () {
      final file = writeFile(buildM4a(ilstItems: custom));

      final handler = MP4Handler(file.path);
      expect(handler.getMetadata<String>('com.apple.iTunes.MOOD'), 'calm');
      expect(handler.getMetadata<String>('com.apple.iTunes.SOURCE'), 'vinyl');
    });

    test('are replaced one at a time', () async {
      final file = writeFile(buildM4a(ilstItems: custom));

      final handler = MP4Handler(file.path);
      handler.updateMetadata({'com.apple.iTunes.MOOD': 'lively'});
      await handler.applyMetadataChanges();

      final reread = MP4Handler(file.path);
      expect(reread.getMetadata<String>('com.apple.iTunes.MOOD'), 'lively');
      expect(reread.getMetadata<String>('com.apple.iTunes.SOURCE'), 'vinyl');
      expect(reread.getMetadata<String>('title'), 'Title');
      expectChunksIntact(file.readAsBytesSync());
    });

    test('can be added and removed', () async {
      final file = writeFile(buildM4a(ilstItems: custom));

      final handler = MP4Handler(file.path);
      handler.addMetadata({
        'com.apple.iTunes.TEMPO': 'slow',
        'com.example.n': 7,
      });
      handler.removeMetadata(['com.apple.iTunes.SOURCE']);
      await handler.applyMetadataChanges();

      final reread = MP4Handler(file.path);
      expect(reread.getMetadata<String>('com.apple.iTunes.TEMPO'), 'slow');
      expect(reread.getMetadata<int>('com.example.n'), 7);
      expect(reread.metadata.contains('com.apple.iTunes.SOURCE'), isFalse);
      expect(reread.getMetadata<String>('com.apple.iTunes.MOOD'), 'calm');
    });
  });

  group('cover art', () {
    test('several covers are written and read', () async {
      final file = writeFile(buildM4a(ilstItems: tagged));
      final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 5, 6, 7, 8]);
      final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4]);

      final handler = MP4Handler(file.path);
      handler.updateMetadata({
        'cover': [jpeg, png],
      });
      await handler.applyMetadataChanges();

      final reread = MP4Handler(file.path);
      expect(reread.getMetadata<Uint8List>('cover'), jpeg);
      expect(reread.getMetadata<List>('covers'), [jpeg, png]);

      final bytes = file.readAsBytesSync();
      final covr = findBox(bytes, ['moov', 'udta', 'meta', 'ilst', 'covr'])!;
      expect(bytes[covr.start + 8 + 3], 13);
      expectChunksIntact(bytes);
    });

    test(
      'adding a cover keeps the covers that are there, updating replaces',
      () async {
        final file = writeFile(buildM4a(ilstItems: tagged));
        final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 5, 6, 7, 8]);
        final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4]);
        final gif = Uint8List.fromList([0x47, 0x49, 0x46, 0x38, 9, 9, 9, 9]);

        final first = MP4Handler(file.path);
        first.updateMetadata({'cover': jpeg});
        await first.applyMetadataChanges();

        final second = MP4Handler(file.path);
        second.addMetadata({'cover': png});
        second.addMetadata({
          'cover': [gif],
        });
        await second.applyMetadataChanges();

        expect(MP4Handler(file.path).getMetadata<List>('covers'), [
          jpeg,
          png,
          gif,
        ]);

        // The other items and the media are untouched.
        final bytes = file.readAsBytesSync();
        expectChunksIntact(bytes);

        final third = MP4Handler(file.path);
        third.updateMetadata({'cover': png});
        await third.applyMetadataChanges();
        expect(MP4Handler(file.path).getMetadata<List>('covers'), [png]);
      },
    );

    test('an empty list of covers throws', () async {
      final file = writeFile(buildM4a(ilstItems: tagged));

      final handler = MP4Handler(file.path);
      handler.updateMetadata({'cover': <Uint8List>[]});

      await expectLater(
        handler.applyMetadataChanges(),
        throwsA(isA<MP4Exception>()),
      );
    });
  });

  group('reading', () {
    test('decodes big-endian UTF-16 text', () {
      // 'Hé日' in UTF-16BE, data type 2.
      final file = writeFile(
        buildM4a(
          ilstItems: item('©nam', 2, [0x00, 0x48, 0x00, 0xE9, 0x65, 0xE5]),
        ),
      );

      expect(MP4Handler(file.path).getMetadata<String>('title'), 'Hé日');
    });
  });

  group('values', () {
    test('reads track and disc pairs, and writes them back', () async {
      final file = writeFile(
        buildM4a(
          ilstItems: [
            ...item('trkn', 0, [0, 0, 0, 1, 0, 9, 0, 0]),
            ...item('disk', 0, [0, 0, 0, 2, 0, 3]),
          ],
        ),
      );

      final handler = MP4Handler(file.path);
      expect(handler.getMetadata<List<int>>('trackNumber'), [1, 9]);
      expect(handler.getMetadata<List<int>>('discNumber'), [2, 3]);

      handler.updateMetadata({
        'trackNumber': [3, 12],
        'discNumber': [1, 2],
      });
      await handler.applyMetadataChanges();

      final bytes = file.readAsBytesSync();
      final trkn = findBox(bytes, ['moov', 'udta', 'meta', 'ilst', 'trkn'])!;
      final disk = findBox(bytes, ['moov', 'udta', 'meta', 'ilst', 'disk'])!;
      // 8-byte data header, then 8 bytes for tracks and 6 for discs.
      expect(trkn.end - trkn.start, 8 + 8 + 8);
      expect(disk.end - disk.start, 8 + 8 + 6);

      final reread = MP4Handler(file.path);
      expect(reread.getMetadata<List<int>>('trackNumber'), [3, 12]);
      expect(reread.getMetadata<List<int>>('discNumber'), [1, 2]);
    });

    test('writes tempo, rating and flags as integers', () async {
      final file = writeFile(buildM4a(ilstItems: tagged));

      final handler = MP4Handler(file.path);
      handler.addMetadata({
        'bpm': 128,
        'rating': 1,
        'compilation': true,
        'gapless': false,
      });
      await handler.applyMetadataChanges();

      final reread = MP4Handler(file.path);
      expect(reread.getMetadata<int>('bpm'), 128);
      expect(reread.getMetadata<int>('rating'), 1);
      expect(reread.getMetadata<bool>('compilation'), isTrue);
      expect(reread.getMetadata<bool>('gapless'), isFalse);
    });

    test('writes a number given for a text atom as text', () async {
      final file = writeFile(buildM4a(ilstItems: tagged));

      final handler = MP4Handler(file.path);
      handler.updateMetadata({'year': 1999});
      await handler.applyMetadataChanges();

      expect(MP4Handler(file.path).getMetadata<String>('year'), '1999');
    });

    test('writes cover art with the right data type', () async {
      final file = writeFile(buildM4a(ilstItems: tagged));
      final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4]);
      final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 5, 6, 7, 8]);

      final handler = MP4Handler(file.path);
      handler.updateMetadata({'cover': png});
      await handler.applyMetadataChanges();

      var bytes = file.readAsBytesSync();
      var covr = findBox(bytes, ['moov', 'udta', 'meta', 'ilst', 'covr'])!;
      // 8-byte data atom header, then version and flags.
      expect(bytes[covr.start + 8 + 3], 14);
      expect(MP4Handler(file.path).getMetadata<Uint8List>('cover'), png);

      final second = MP4Handler(file.path);
      second.updateMetadata({'cover': jpeg});
      await second.applyMetadataChanges();

      bytes = file.readAsBytesSync();
      covr = findBox(bytes, ['moov', 'udta', 'meta', 'ilst', 'covr'])!;
      expect(bytes[covr.start + 8 + 3], 13);
      expect(MP4Handler(file.path).getMetadata<Uint8List>('cover'), jpeg);
    });

    test('keeps non-ASCII text', () async {
      final file = writeFile(buildM4a(ilstItems: tagged));

      final handler = MP4Handler(file.path);
      handler.updateMetadata({'title': 'Café 日本語'});
      await handler.applyMetadataChanges();

      expect(MP4Handler(file.path).getMetadata<String>('title'), 'Café 日本語');
    });
  });

  group('failures', () {
    test('an invalid key throws and leaves the file untouched', () async {
      final original = buildM4a(ilstItems: tagged);
      final file = writeFile(original);

      final handler = MP4Handler(file.path);
      handler.updateMetadata({'title': 'Changed', 'abc': 'x'});

      await expectLater(
        handler.applyMetadataChanges(),
        throwsA(isA<MP4Exception>()),
      );
      expect(file.readAsBytesSync(), original);
      expect(File('${file.path}.tmp').existsSync(), isFalse);
      expect(handler.getMetadata<String>('title'), 'Old title');

      // The handler is still usable once the bad operation is dropped.
      handler.clearPendingOperations();
      handler.updateMetadata({'title': 'Fixed'});
      await handler.applyMetadataChanges();
      expect(MP4Handler(file.path).getMetadata<String>('title'), 'Fixed');
      expectChunksIntact(file.readAsBytesSync());
    });

    test(
      'a value the atom cannot hold throws and leaves the file untouched',
      () async {
        final original = buildM4a(ilstItems: tagged);
        final file = writeFile(original);

        final handler = MP4Handler(file.path);
        handler.updateMetadata({'trackNumber': 'three'});

        await expectLater(
          handler.applyMetadataChanges(),
          throwsA(isA<MP4Exception>()),
        );
        expect(file.readAsBytesSync(), original);
      },
    );

    test('a file that is not an MP4 does not throw from the constructor', () {
      final file = writeFile([1, 2, 3]);

      final handler = MP4Handler(file.path);
      expect(handler.metadata.contains('title'), isFalse);
    });
  });
}
