import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:math' as math;

import 'package:archive/archive.dart';
import 'package:logger/logger.dart';

import 'exceptions.dart';
import 'genres.dart';
import 'id3_tags.dart';
import 'handler.dart';
import 'metadata.dart';

final Map<String, String> _friendlyToFrameIds = {
  'title': 'TIT2',
  'artist': 'TPE1',
  'album': 'TALB',
  'albumArtist': 'TPE2',
  'year': 'TYER',
  'recordingTime': 'TDRC',
  'track': 'TRCK',
  'genre': 'TCON',
  'comment': 'COMM',
  'picture': 'APIC',
  'composer': 'TCOM',
  'conductor': 'TPE3',
  'copyright': 'TCOP',
  'discNumber': 'TPOS',
  'encodedBy': 'TENC',
  'mood': 'TMOO',
  'originalArtist': 'TOPE',
  'bpm': 'TBPM',
  'publisher': 'TPUB',
  'isrc': 'TSRC',
  'language': 'TLAN',
  'lyrics': 'USLT',
  'synchronizedLyrics': 'SYLT',
  'involvedPeople': 'TIPL',
  'musicianCredits': 'TMCL',
  'encodingTime': 'TDEN',
  'originalReleaseTime': 'TDOR',
  'releaseTime': 'TDRL',
  'taggingTime': 'TDTG',
  'website': 'WOAR',
  'userDefinedUrl': 'WXXX',
  'rating': 'POPM',
  'replayGain': 'RVA2',
};

String _frameIdToKey(String frameId) {
  return _friendlyToFrameIds.entries
      .firstWhere(
        (entry) => entry.value == frameId,
        orElse: () => MapEntry(frameId.toLowerCase(), frameId),
      )
      .key;
}

/// A class to handle ID3 tag operations.This class provides methods for
/// reading, writing, and manipulating ID3 tags in various formats.
/// It supports ID3v1, ID3v2, and APEv2 tag formats.
class ID3Handler extends CodecHandler {
  /// The ID3v2 tag being handled.
  late ID3v2Tag _id3v2Tag;

  /// Offset of the first byte after the ID3v2 tag (0 if there is none).
  int _audioStart = 0;

  /// Whether the ID3v2.4 tag being parsed says all its frames are
  /// unsynchronized.
  bool _tagUnsynchronized = false;

  /// The version of the ID3v2 tag being parsed. The tag itself is only set
  /// once parsing is done.
  int _parseVersion = 4;

  /// Every APIC frame of the tag, in order. `picture` is the last one.
  List<Map<String, dynamic>> _pictures = [];

  /// A map of custom frame handlers for handling unknown or unsupported frames.
  final Map<String, Function> _customFrameHandlers = {};

  /// A map of grouped frames, used for storing frames that are part of a group.
  final Map<String, List<Map<String, dynamic>>> _groupedFrames = {};

  /// Reads the metadata of the file at [path] in a separate isolate, so the
  /// calling isolate (the UI isolate of a Flutter app, for example) is not
  /// blocked by the file reads. Returns the same [Metadata] that
  /// `ID3Handler(path).metadata` has.
  ///
  /// [Logger.level] is set per isolate, so the level in use here is passed on.
  static Future<Metadata> readMetadata(String path) {
    final level = Logger.level;
    return Isolate.run(() {
      Logger.level = level;
      return ID3Handler(path).metadata;
    });
  }

  ID3Handler(super.filePath) {
    parseMetadata();
  }

  /// Registers a custom frame handler for a specific ID3v2 frame.
  ///
  /// This function allows you to define custom logic for parsing and handling
  /// specific ID3v2 frames. When an ID3v2 tag is parsed, if a handler is registered
  /// for a particular frame ID, the handler will be called instead of the default
  /// parsing logic.
  ///
  /// The [frameId] parameter is the ID of the ID3v2 frame for which the handler should
  /// be registered. The [handler] parameter is a function that takes a [Uint8List]
  /// representing the raw frame data and returns a custom object representing the
  /// parsed frame data.
  ///
  /// The function does not return any value.
  void registerCustomFrameHandler(String frameId, Function handler) {
    _customFrameHandlers[frameId] = handler;
  }

  @override
  void parseMetadata() {
    openRead();
    metadata.clear();
    _pictures = [];
    try {
      _id3v2Tag = _parseID3v2();
      _parseID3v1();
      _parseAPEv2();
      _parseVorbisComments();
      _calculateDuration();
      if (metadata.asMap().isNotEmpty) {
        setMetadata('filePath', file.path);
      }
    } catch (e) {
      logger.w('Error parsing metadata: $e');
    } finally {
      close();
    }
  }

  /// Parses an ID3v2 tag from the given file.
  ///
  /// The function reads the file's header and checks if it's a valid ID3v2 tag.
  /// If the tag is valid, it parses the tag's version, revision, flags, size,
  /// and the list of frames it contains.
  ///
  /// If the tag contains an extended header, it parses the extended header.
  /// It then parses the frames, handling unsynchronization if present.
  ///
  /// If the tag contains a footer, it parses the footer.
  ///
  /// The function returns an [ID3v2Tag] object containing the parsed tag's information.
  ID3v2Tag _parseID3v2() {
    file.setPositionSync(0);
    var header = file.readSync(10);
    if (String.fromCharCodes(header.sublist(0, 3)) == 'ID3') {
      int version = header[3];
      int revision = header[4];
      int flags = header[5];
      int size = _syncSafeInteger(header.sublist(6, 10));

      logger.i('Found ID3v2.$version.$revision tag, size: $size bytes');

      bool unsynchronization = (flags & 0x80) != 0;
      bool extendedHeader = (flags & 0x40) != 0;
      bool experimentalIndicator = (flags & 0x20) != 0;
      bool footerPresent = version == 4 && (flags & 0x10) != 0;

      if (experimentalIndicator) {
        logger.w(
          'Experimental indicator is set. Tag may contain experimental features.',
        );
      }

      var tagData = file.readSync(size);
      // In ID3v2.3 the whole tag is unsynchronized. In ID3v2.4 it is done frame
      // by frame, and the tag flag says that all of them are.
      _tagUnsynchronized = version == 4 && unsynchronization;
      if (unsynchronization && version != 4) {
        tagData = _removeUnsynchronization(tagData);
      }

      int dataOffset = 0;
      if (extendedHeader) {
        dataOffset = _parseExtendedHeader(tagData, version);
      }

      List<ID3v2Frame> frames = _parseID3v2Frames(
        tagData.sublist(dataOffset),
        version,
      );

      if (footerPresent) {
        _parseID3v2Footer(file.readSync(10));
      }

      _audioStart = 10 + size + (footerPresent ? 10 : 0);
      return ID3v2Tag(version, revision, flags, size, frames);
    } else {
      logger.w('No ID3v2 tag found');
      _audioStart = 0;
      return ID3v2Tag(0, 0, 0, 0, []);
    }
  }

  /// Parses the ID3v2 extended header based on the given version.
  ///
  /// This function extracts the size of the extended header and returns it.
  /// If the version is 3, it also parses the ID3v2.3 extended header.
  /// If the version is 4, it also parses the ID3v2.4 extended header.
  ///
  /// Parameters:
  /// - [data]: The byte data containing the extended header.
  /// - [version]: The version of the ID3v2 tag (3 or 4).
  ///
  /// Returns:
  /// - The size of the extended header, including the header size.
  int _parseExtendedHeader(Uint8List data, int version) {
    if (version == 3) {
      int size = ByteData.view(data.buffer).getUint32(0);
      // Parse ID3v2.3 extended header...
      return size + 4;
    } else if (version == 4) {
      int size = _syncSafeInteger(data.sublist(0, 4));
      // Parse ID3v2.4 extended header...
      return size;
    }
    return 0;
  }

  /// Parses the ID3v2 footer from the given [footer] data.
  ///
  /// The function checks if the footer starts with the '3DI' identifier, indicating an ID3v2.4 footer.
  /// If found, it extracts and logs the version and revision numbers, as well as the total size of the footer.
  ///
  /// Parameters:
  /// - [footer]: A [Uint8List] containing the footer data to be parsed.
  ///
  /// Returns:
  /// - Nothing.
  void _parseID3v2Footer(Uint8List footer) {
    if (String.fromCharCodes(footer.sublist(0, 3)) == '3DI') {
      logger.i('ID3v2.4 footer found');
      int version = footer[3];
      int revision = footer[4];
      // int flags = footer[5];
      int size = _syncSafeInteger(footer.sublist(6, 10));

      logger.i('Footer version: $version.$revision, size: $size bytes');
    }
  }

  /// Parses ID3v2 frames from the given data.
  ///
  /// This function iterates through the data, extracting each frame and parsing its content.
  /// It handles different frame types, including standard and custom frames.
  ///
  /// Parameters:
  /// - [data]: The byte data containing the ID3v2 frames.
  /// - [version]: The version of the ID3v2 tag (2 or 4).
  ///
  /// Returns:
  /// A list of [ID3v2Frame] objects, each representing a parsed frame.
  List<ID3v2Frame> _parseID3v2Frames(Uint8List data, int version) {
    _parseVersion = version;
    List<ID3v2Frame> frames = [];
    int offset = 0;

    while (offset < data.length) {
      if (offset + 10 > data.length) {
        logger.w('Unexpected end of ID3v2 tag data');
        break;
      }

      var frameHeader = data.sublist(offset, offset + 10);
      String frameId = String.fromCharCodes(frameHeader.sublist(0, 4));
      int frameSize = version == 4
          ? _syncSafeInteger(frameHeader.sublist(4, 8))
          : ByteData.view(frameHeader.buffer).getUint32(4, Endian.big);
      int frameFlags = ByteData.view(
        frameHeader.buffer,
      ).getUint16(8, Endian.big);

      if (frameId == '\x00\x00\x00\x00') break;

      if (offset + 10 + frameSize > data.length) {
        logger.w('Invalid frame size for $frameId');
        break;
      }

      var frameData = data.sublist(offset + 10, offset + 10 + frameSize);
      try {
        // Remember that a frame is unsynchronized even when only the tag says
        // so, since the tag flag is not written back.
        if (version == 4 && _tagUnsynchronized) frameFlags |= 0x0002;
        ID3v2Frame frame = ID3v2Frame(
          frameId,
          frameSize,
          frameData,
          flags: frameFlags,
        );
        // Keep the frame even if its metadata cannot be parsed, so that
        // writing the tag back does not lose it.
        frames.add(frame);
        _parseID3v2Frame(frame, frameFlags, version);
      } catch (e) {
        logger.w('Error parsing frame $frameId: $e');
      }

      offset += 10 + frameSize;
    }

    return frames;
  }

  /// Parses an ID3v2 frame.
  ///
  /// This function handles the parsing of ID3v2 frames, including handling of
  /// frame flags, decompression of compressed frames, and handling of custom
  /// frame handlers.
  ///
  /// Parameters:
  /// - [frame]: The ID3v2 frame to be parsed.
  /// - [frameFlags]: The flags associated with the frame.
  /// - [version]: The version of the ID3v2 tag.
  void _parseID3v2Frame(ID3v2Frame frame, int frameFlags, int version) {
    bool dataLengthIndicator = (frameFlags & 0x0001) != 0;
    bool compressed = (frameFlags & 0x0008) != 0;
    bool encrypted = (frameFlags & 0x0004) != 0;
    bool grouped = (frameFlags & 0x0040) != 0;

    if (encrypted) {
      logger.w('Encrypted frames are not supported: ${frame.id}');
      return;
    }

    int dataOffset = dataLengthIndicator ? 4 : 0;
    Uint8List decompressedData = frame.data.sublist(dataOffset);
    if (version == 4 && (frameFlags & 0x0002) != 0) {
      decompressedData = _removeUnsynchronization(decompressedData);
    }

    if (compressed) {
      try {
        int decompressedSize = _syncSafeInteger(frame.data.sublist(0, 4));
        decompressedData = Uint8List.fromList(
          ZLibDecoder().decodeBytes(decompressedData),
        );
        if (decompressedData.length != decompressedSize) {
          logger.w('Decompressed size mismatch for frame ${frame.id}');
        }
      } catch (e) {
        logger.e('Error decompressing frame ${frame.id}: $e');
        return;
      }
    }

    if (grouped) {
      _handleGroupedFrame(frame.id, decompressedData, version);
      return;
    }

    if (_customFrameHandlers.containsKey(frame.id)) {
      _customFrameHandlers[frame.id]!(decompressedData, version);
      return;
    }

    _parseStandardFrame(frame.id, decompressedData);
  }

  /// Parses a standard ID3v2 frame.
  ///
  /// This function handles the parsing of various standard ID3v2 frames, such as text frames,
  /// user-defined text frames, comment frames, attached picture frames, unsynchronized lyrics frames,
  /// synchronized lyrics frames, chapter frames, table of contents frames, and private frames.
  ///
  /// [frameId] The ID of the frame to be parsed.
  /// [data] The raw data of the frame.
  void _parseStandardFrame(String frameId, Uint8List data) {
    switch (frameId) {
      case 'TIT2':
      case 'TPE1':
      case 'TPE2':
      case 'TALB':
      case 'TYER':
      case 'TDRC':
      case 'TCON':
      case 'TRCK':
      case 'TPOS':
        _parseTextFrame(frameId, data);
        break;
      case 'TXXX':
        _parseUserDefinedTextFrame(data);
        break;
      case 'WXXX':
        _parseUserDefinedUrlFrame(data);
        break;
      case 'COMM':
        _parseCommentFrame(data);
        break;
      case 'APIC':
        _parseAPICFrame(data);
        break;
      case 'POPM':
        _parsePopularimeterFrame(data);
        break;
      case 'USLT':
        _parseUnsynchronizedLyricsFrame(data);
        break;
      case 'SYLT':
        _parseSynchronizedLyricsFrame(data, _parseVersion);
        break;
      case 'CHAP':
        _parseChapterFrame(data, _parseVersion);
        break;
      case 'CTOC':
        _parseTableOfContentsFrame(data, _parseVersion);
        break;
      case 'PRIV':
        _parsePrivateFrame(data);
        break;
      default:
        logger.i('Unhandled ID3v2 frame: $frameId');
    }
  }

  /// Handles grouped frames in ID3v2 tag.
  ///
  /// This function extracts the group ID and the data associated with the group from the given
  /// [data] and adds it to the list of grouped frames for the given [frameId]. If the list for the
  /// given [frameId] does not exist, it is created.
  ///
  /// Parameters:
  /// - [frameId]: The ID of the frame containing the grouped data.
  /// - [data]: The raw data of the grouped frame.
  /// - [version]: The version of the ID3v2 tag.
  void _handleGroupedFrame(String frameId, Uint8List data, int version) {
    int groupId = data[0];
    var frameData = data.sublist(1);

    if (!_groupedFrames.containsKey(frameId)) {
      _groupedFrames[frameId] = [];
    }

    _groupedFrames[frameId]!.add({'groupId': groupId, 'data': frameData});
  }

  /// Parses the ID3v2 synchronized lyrics frame.
  ///
  /// This function extracts the language, time stamp format, content type, description,
  /// and synchronized lyrics from the given [data] and sets the corresponding metadata.
  ///
  /// Parameters:
  /// - [data]: The raw data of the synchronized lyrics frame.
  /// - [version]: The version of the ID3v2 tag.
  void _parseSynchronizedLyricsFrame(Uint8List data, int version) {
    if (data.length < 7) return;
    final encoding = data[0];
    final language = String.fromCharCodes(data.sublist(1, 4));
    final timeStampFormat = data[4];
    final contentType = data[5];
    final step = encoding == 1 || encoding == 2 ? 2 : 1;

    var offset = 6;
    final descriptionEnd = _findNullTerminator(data, offset, encoding);
    final description = _decodeString(
      data.sublist(offset, descriptionEnd),
      encoding,
    );
    offset = descriptionEnd + step;

    // Each entry is a string, its terminator, and a 4-byte time stamp. The
    // time stamps are binary, so the entries cannot be found by splitting on
    // zero bytes.
    final syncedLyrics = <Map<String, dynamic>>[];
    final view = ByteData.sublistView(data);
    while (offset < data.length) {
      final end = _findNullTerminator(data, offset, encoding);
      final text = _decodeString(data.sublist(offset, end), encoding);
      offset = end + step;
      if (offset + 4 > data.length) break;
      syncedLyrics.add({'timeStamp': view.getUint32(offset), 'text': text});
      offset += 4;
    }

    setMetadata('synchronizedLyrics', {
      'language': language,
      'timeStampFormat': timeStampFormat,
      'contentType': contentType,
      'description': description,
      'lyrics': syncedLyrics,
    });
  }

  /// Parses the ID3v2 user defined URL frame (`WXXX`): an encoding byte, a
  /// description and a URL, which is always ISO-8859-1.
  void _parseUserDefinedUrlFrame(Uint8List data) {
    if (data.isEmpty) return;
    final encoding = data[0];
    final step = encoding == 1 || encoding == 2 ? 2 : 1;
    final end = _findNullTerminator(data, 1, encoding);
    final description = _decodeString(data.sublist(1, end), encoding);
    final urlStart = math.min(end + step, data.length);
    setMetadata('userDefinedUrl', {
      'description': description,
      'url': latin1.decode(data.sublist(urlStart), allowInvalid: true),
    });
  }

  /// The text frames inside the frames of a `CHAP` or `CTOC` frame, as frame
  /// ID to text. Other frames in there are left out.
  Map<String, String> _readSubFrames(Uint8List data, int version) {
    final texts = <String, String>{};
    final view = ByteData.sublistView(data);
    var offset = 0;
    while (offset + 10 <= data.length && data[offset] != 0) {
      final id = String.fromCharCodes(data.sublist(offset, offset + 4));
      final size = version == 4
          ? _syncSafeInteger(data.sublist(offset + 4, offset + 8))
          : view.getUint32(offset + 4);
      offset += 10;
      if (offset + size > data.length) break;
      if (id.startsWith('T') && id != 'TXXX') {
        final values = _decodeTextFrame(data.sublist(offset, offset + size));
        if (values.isNotEmpty) texts[id] = values.first;
      }
      offset += size;
    }
    return texts;
  }

  /// Parses the ID3v2 chapter frame.
  ///
  /// This function extracts the chapter element ID, start and end times, start and end offsets,
  /// and the text sub-frames (the chapter title is in `TIT2`) from the given [data] and [version].
  /// It then sets the extracted information as metadata with the key 'chapter_{elementId}'.
  /// The sub-frames are not added to the metadata of the file itself.
  ///
  /// Parameters:
  /// - [data]: The byte data containing the chapter frame.
  /// - [version]: The version of the ID3v2 tag.
  void _parseChapterFrame(Uint8List data, int version) {
    final elementIdEnd = data.indexOf(0);
    if (elementIdEnd == -1 || elementIdEnd + 17 > data.length) return;
    final elementId = latin1.decode(data.sublist(0, elementIdEnd));
    final view = ByteData.sublistView(data);
    final subFrames = _readSubFrames(data.sublist(elementIdEnd + 17), version);
    setMetadata('chapter_$elementId', {
      'elementId': elementId,
      'startTime': view.getUint32(elementIdEnd + 1),
      'endTime': view.getUint32(elementIdEnd + 5),
      'startOffset': view.getUint32(elementIdEnd + 9),
      'endOffset': view.getUint32(elementIdEnd + 13),
      'subFrames': subFrames,
      if (subFrames.containsKey('TIT2')) 'title': subFrames['TIT2'],
    });
  }

  /// Parses the ID3v2 table of contents (TOC) frame.
  ///
  /// This function extracts the element ID, flags, entry count, child IDs, and text sub-frames from the given [data] and [version].
  /// It then sets the extracted information as metadata with the key 'tableOfContents_{elementId}'.
  ///
  /// Parameters:
  /// - [data]: The byte data containing the TOC frame.
  /// - [version]: The version of the ID3v2 tag.
  void _parseTableOfContentsFrame(Uint8List data, int version) {
    final elementIdEnd = data.indexOf(0);
    if (elementIdEnd == -1 || elementIdEnd + 3 > data.length) return;
    final elementId = latin1.decode(data.sublist(0, elementIdEnd));
    final flags = data[elementIdEnd + 1];
    final entryCount = data[elementIdEnd + 2];
    final children = <String>[];
    var offset = elementIdEnd + 3;
    for (var i = 0; i < entryCount; i++) {
      final childIdEnd = data.indexOf(0, offset);
      if (childIdEnd == -1) return;
      children.add(latin1.decode(data.sublist(offset, childIdEnd)));
      offset = childIdEnd + 1;
    }
    final subFrames = _readSubFrames(data.sublist(offset), version);
    setMetadata('tableOfContents_$elementId', {
      'elementId': elementId,
      'isOrdered': (flags & 0x01) != 0,
      'isTopLevel': (flags & 0x02) != 0,
      'children': children,
      'subFrames': subFrames,
      if (subFrames.containsKey('TIT2')) 'title': subFrames['TIT2'],
    });
  }

  /// Parses the ID3v2 private frame and sets the corresponding metadata.
  ///
  /// The private frame contains binary data that is not intended to be interpreted by the ID3 standard.
  ///
  /// Parameters:
  /// - [data]: A [Uint8List] containing the binary data of the private frame.
  ///
  /// The function extracts the owner identifier and the private data from the frame.
  /// It then sets the metadata with the key 'private_$ownerId' and the value as the private data.
  void _parsePrivateFrame(Uint8List data) {
    int ownerIdEnd = data.indexOf(0);
    String ownerId = String.fromCharCodes(data.sublist(0, ownerIdEnd));
    var privateData = data.sublist(ownerIdEnd + 1);
    setMetadata('private_$ownerId', privateData);
  }

  /// Parses a text frame from the ID3v2 tag.
  ///
  /// The function decodes the text frame data based on the specified frame ID and encoding.
  /// It then extracts the relevant information and sets it as metadata.
  ///
  /// Parameters:
  /// - [frameId]: A string representing the ID of the text frame.
  /// - [data]: A [Uint8List] containing the binary data of the text frame.
  void _parseTextFrame(String frameId, Uint8List data) {
    List<String> textValues = _decodeTextFrame(data);
    String key = _frameIdToKey(frameId);

    if (textValues.isEmpty) {
      logger.w('Empty text frame for $frameId');
      return;
    }

    switch (frameId) {
      case 'TRCK':
      case 'TPOS':
        _parseNumberPairFrame(key, textValues[0]);
        break;
      case 'TCON':
        _parseGenreFrame(textValues);
        break;
      case 'TDRC':
        setMetadata(key, textValues.length > 1 ? textValues : textValues[0]);
        // ID3v2.4 keeps the year in the recording time, 'TYER' is gone.
        final year = RegExp(r'^\d{4}').firstMatch(textValues[0])?.group(0);
        if (year != null && !metadata.contains('year')) {
          setMetadata('year', year);
        }
        break;
      default:
        if (textValues.length > 1) {
          setMetadata(key, textValues);
        } else {
          setMetadata(key, textValues[0]);
        }
    }
  }

  void _parseNumberPairFrame(String key, String value) {
    List<int> numbers = value
        .split('/')
        .map((s) => int.tryParse(s.trim()))
        .where((n) => n != null)
        .cast<int>()
        .toList();

    if (numbers.isNotEmpty) {
      if (numbers.length == 1) {
        numbers.add(0); // Add 0 as total if not provided
      }
      setMetadata(key, numbers);
    }
  }

  void _parseGenreFrame(List<String> values) {
    List<String> genreList = [];
    for (String value in values) {
      if (value.startsWith('(') && value.contains(')')) {
        // Handle numeric genre codes
        int? genreCode = int.tryParse(value.substring(1, value.indexOf(')')));
        if (genreCode != null && genreCode < genres.length) {
          genreList.add(genres[genreCode]);
        } else {
          genreList.add(value.substring(value.indexOf(')') + 1).trim());
        }
      } else {
        genreList.add(value);
      }
    }
    setMetadata('genre', genreList.length == 1 ? genreList[0] : genreList);
  }

  String capitalize(String s) => s[0].toUpperCase() + s.substring(1);

  /// Parses a user-defined text frame from the ID3v2 tag.
  ///
  /// This function extracts the encoding, description, and value from the given data.
  /// It then sets the metadata with the key 'userDefinedText' and the extracted information.
  ///
  /// Parameters:
  /// - [data]: A [Uint8List] containing the binary data of the user-defined text frame.
  ///
  /// The encoding is determined by the first byte of the data.
  /// The description and value are split by null terminators.
  ///
  /// The function does not return any value.
  void _parseUserDefinedTextFrame(Uint8List data) {
    int encoding = data[0];
    List<Uint8List> parts = _splitNullTerminated(data.sublist(1), encoding);
    if (parts.length >= 2) {
      String description = _decodeString(parts[0], encoding);
      String value = _decodeString(parts[1], encoding);
      setMetadata('userDefinedText', {
        'description': description,
        'value': value,
      });
    }
  }

  /// Decodes the text frame data based on the specified encoding.
  ///
  /// Parameters:
  /// - [data]: A [Uint8List] containing the binary data of the text frame.
  ///
  /// Returns:
  /// A [String] representing the decoded text.
  ///
  /// The function decodes the text frame data based on the specified frame ID and encoding.
  /// It then extracts the relevant information and returns it as a string.
  /// If the encoding is unknown, it logs a warning and returns the decoded text using ISO-8859-1 encoding.
  List<String> _decodeTextFrame(Uint8List data) {
    if (data.isEmpty) return [];
    int encoding = data[0];
    Uint8List textData = data.sublist(1);

    List<String> decodedStrings = [];
    try {
      switch (encoding) {
        case 0: // ISO-8859-1
          decodedStrings = latin1.decode(textData).split('\x00');
          break;
        case 1: // UTF-16 with BOM
        case 2: // UTF-16BE without BOM
          decodedStrings = _decodeUTF16(textData).split('\u0000');
          break;
        case 3: // UTF-8
          decodedStrings = utf8.decode(textData).split('\x00');
          break;
        default:
          logger.w(
            'Unknown text encoding: $encoding, falling back to ISO-8859-1',
          );
          decodedStrings = latin1.decode(textData).split('\x00');
      }
    } catch (e) {
      logger.e('Error decoding text frame: $e');
      // Fallback to Latin-1 in case of decoding errors
      decodedStrings = latin1.decode(textData).split('\x00');
    }
    return decodedStrings
        .where((s) => s.isNotEmpty)
        .map((s) => s.trim())
        .toList();
  }

  /// Decodes the UTF-16 encoded data.
  ///
  /// The function checks for a Byte Order Mark (BOM) at the beginning of the data.
  /// If a BOM is found, it determines the endianness of the data and decodes it accordingly.
  /// If no BOM is found, it assumes the data is encoded in big-endian order.
  ///
  /// The function trims any trailing whitespace from the decoded string.
  ///
  /// Parameters:
  /// - [data]: A [Uint8List] containing the UTF-16 encoded data.
  ///
  /// Returns:
  /// A [String] representing the decoded UTF-16 data.
  String _decodeUTF16(Uint8List data) {
    if (data.length < 2) return '';
    ByteData byteData = ByteData.sublistView(data);

    bool isLittleEndian = (data[0] == 0xFF && data[1] == 0xFE);
    int offset = (data[0] == 0xFF || data[0] == 0xFE) ? 2 : 0;

    List<int> codeUnits = [];
    for (int i = offset; i < data.length; i += 2) {
      if (i + 1 < data.length) {
        int codeUnit = isLittleEndian
            ? byteData.getUint16(i, Endian.little)
            : byteData.getUint16(i, Endian.big);
        codeUnits.add(codeUnit);
      }
    }
    return String.fromCharCodes(codeUnits);
  }

  /// Parses the comment frame data and sets the corresponding metadata.
  ///
  /// The comment frame contains information about the comment, such as the language and text.
  /// This function decodes the comment frame data using the specified encoding and sets the metadata accordingly.
  ///
  /// Parameters:
  /// - [data]: A [Uint8List] containing the comment frame data.
  void _parseCommentFrame(Uint8List data) {
    int encoding = data[0];
    String language = String.fromCharCodes(data.sublist(1, 4));
    Uint8List contentData = data.sublist(4);
    List<Uint8List> parts = _splitNullTerminated(contentData, encoding);
    if (parts.length >= 2) {
      String description = _decodeString(parts[0], encoding);
      String text = _decodeString(parts[1], encoding);
      setMetadata('comment', {
        'language': language,
        'description': description,
        'text': text,
      });
    }
  }

  /// Parses the APIC (Attached Picture) frame data and sets the corresponding metadata.
  ///
  /// The APIC frame contains information about the attached picture, such as the MIME type, picture type, description, and picture data.
  /// This function decodes the APIC frame data using the specified encoding and sets the metadata accordingly.
  ///
  /// Parameters:
  /// - [data]: A [Uint8List] containing the APIC frame data.
  void _parseAPICFrame(Uint8List data) {
    int encoding = data[0];
    int mimeTypeEnd = data.indexOf(0, 1);
    String mimeType = latin1.decode(data.sublist(1, mimeTypeEnd));
    int pictureType = data[mimeTypeEnd + 1];
    int descriptionEnd = _findNullTerminator(data, mimeTypeEnd + 2, encoding);
    String description = _decodeString(
      data.sublist(mimeTypeEnd + 2, descriptionEnd),
      encoding,
    );

    // Calculate the start of the actual image data
    int imageDataStart =
        descriptionEnd + (encoding == 1 || encoding == 2 ? 2 : 1);
    Uint8List pictureData = data.sublist(imageDataStart);

    final picture = {
      'mimeType': mimeType,
      'pictureType': pictureType,
      'description': description,
      'data': pictureData,
    };
    _pictures.add(picture);
    setMetadata('picture', picture);
    setMetadata('pictures', _pictures);
  }

  /// Parses the Unsynchronized Lyrics (USLT) frame data and sets the corresponding metadata.
  ///
  /// The USLT frame contains unsynchronized lyrics, such as lyrics that are not synchronized with the audio.
  /// This function decodes the USLT frame data using the specified encoding and sets the metadata accordingly.
  ///
  /// Parameters:
  /// - [data]: A [Uint8List] containing the USLT frame data.
  /// Parses a POPM frame: the owner's e-mail, the rating (0-255) and a play
  /// counter. The rating is stored as `rating`.
  void _parsePopularimeterFrame(Uint8List data) {
    final ownerEnd = data.indexOf(0);
    if (ownerEnd == -1 || ownerEnd + 1 >= data.length) return;
    setMetadata('rating', data[ownerEnd + 1]);
  }

  void _parseUnsynchronizedLyricsFrame(Uint8List data) {
    int encoding = data[0];
    String language = String.fromCharCodes(data.sublist(1, 4));
    Uint8List contentData = data.sublist(4);
    List<Uint8List> parts = _splitNullTerminated(contentData, encoding);
    if (parts.length >= 2) {
      String description = _decodeString(parts[0], encoding);
      String lyrics = _decodeString(parts[1], encoding);
      setMetadata('unsynchronizedLyrics', {
        'language': language,
        'description': description,
        'text': lyrics,
      });
    }
  }

  int _getBitrate(int version, int layer, int bitrateIndex) {
    // The rows are MPEG-1 layers I, II and III, then MPEG-2 and 2.5 layer I,
    // then MPEG-2 and 2.5 layers II and III.
    final bitrates = [
      [32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448],
      [32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384],
      [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320],
      [32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256],
      [8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160],
    ];

    // Version 1 and layer 0 are reserved. The layer bits are 3 for layer I, 2
    // for layer II and 1 for layer III.
    if (version == 1 || layer == 0 || bitrateIndex < 1 || bitrateIndex > 14) {
      return 0;
    }

    final row = version == 3 ? 3 - layer : (layer == 3 ? 3 : 4);
    return bitrates[row][bitrateIndex - 1];
  }

  Duration? _calculateDuration() {
    try {
      final fileSize = file.lengthSync();
      setMetadata('size', fileSize); // Add file size to metadata

      // Find the first MPEG frame after the ID3v2 tag. There can be padding
      // between the two, so look through the first 64 KiB.
      final start = math.min(_audioStart, fileSize);
      file.setPositionSync(start);
      final data = file.readSync(math.min(64 * 1024, fileSize - start));

      for (var i = 0; i + 4 <= data.length; i++) {
        final frame = _readFrameHeader(data, i);
        if (frame == null) continue;

        // A real frame is followed by another one.
        final next = i + frame.length;
        if (next + 4 <= data.length) {
          final following = _readFrameHeader(data, next);
          if (following == null ||
              following.sampleRate != frame.sampleRate ||
              following.layer != frame.layer) {
            continue;
          }
        }

        final duration = _durationFromFrame(
          data,
          i,
          frame,
          start + i,
          fileSize,
        );
        if (duration != null) {
          _setDurationMetadata(duration);
          return duration;
        }
        break;
      }
    } catch (e) {
      logger.e('Error calculating duration: $e');
    }
    return null;
  }

  /// The duration from the Xing, Info or VBRI header in the first frame, or,
  /// for a constant bitrate file, from its size.
  Duration? _durationFromFrame(
    Uint8List data,
    int offset,
    ({
      int version,
      int layer,
      int bitrate,
      int sampleRate,
      bool mono,
      bool crc,
      int length,
      int samplesPerFrame,
    })
    frame,
    int frameStart,
    int fileSize,
  ) {
    final view = ByteData.sublistView(data);

    // The Xing/Info header sits after the side information of the first frame.
    final sideInfo = frame.version == 3
        ? (frame.mono ? 17 : 32)
        : (frame.mono ? 9 : 17);
    final xing = offset + 4 + (frame.crc ? 2 : 0) + sideInfo;
    if (frame.layer == 1 && xing + 12 <= data.length) {
      final id = String.fromCharCodes(data.sublist(xing, xing + 4));
      if ((id == 'Xing' || id == 'Info') &&
          view.getUint32(xing + 4) & 0x1 != 0) {
        final frames = view.getUint32(xing + 8);
        if (frames > 0) {
          return Duration(
            milliseconds:
                (frames * frame.samplesPerFrame * 1000 / frame.sampleRate)
                    .round(),
          );
        }
      }
    }

    // The VBRI header is always 32 bytes after the frame header.
    final vbri = offset + 4 + 32;
    if (frame.layer == 1 && vbri + 18 <= data.length) {
      if (String.fromCharCodes(data.sublist(vbri, vbri + 4)) == 'VBRI') {
        final frames = view.getUint32(vbri + 14);
        if (frames > 0) {
          return Duration(
            milliseconds:
                (frames * frame.samplesPerFrame * 1000 / frame.sampleRate)
                    .round(),
          );
        }
      }
    }

    // Constant bitrate: the audio bytes divided by the bitrate. An ID3v1 tag
    // at the end of the file is not audio.
    var audioEnd = fileSize;
    if (fileSize - 128 > frameStart) {
      file.setPositionSync(fileSize - 128);
      if (String.fromCharCodes(file.readSync(3)) == 'TAG') audioEnd -= 128;
    }
    // bitrate is in kilobits per second, which is bits per millisecond.
    return Duration(
      milliseconds: ((audioEnd - frameStart) * 8 / frame.bitrate).round(),
    );
  }

  /// Reads the MPEG audio frame header at [i], or returns `null` if the bytes
  /// there are not a valid one.
  ({
    int version,
    int layer,
    int bitrate,
    int sampleRate,
    bool mono,
    bool crc,
    int length,
    int samplesPerFrame,
  })?
  _readFrameHeader(Uint8List data, int i) {
    if (i + 4 > data.length) return null;
    if (data[i] != 0xFF || (data[i + 1] & 0xE0) != 0xE0) return null;

    final version = (data[i + 1] >> 3) & 0x3;
    final layer = (data[i + 1] >> 1) & 0x3;
    final bitrate = _getBitrate(version, layer, data[i + 2] >> 4);
    final sampleRate = _getSampleRate(version, (data[i + 2] >> 2) & 0x3);
    if (version == 1 || layer == 0 || bitrate == 0 || sampleRate == 0) {
      return null;
    }

    final padding = (data[i + 2] >> 1) & 0x1;
    final samplesPerFrame = layer == 3
        ? 384
        : (layer == 2 || version == 3 ? 1152 : 576);
    final length = layer == 3
        ? (12000 * bitrate ~/ sampleRate + padding) * 4
        : (samplesPerFrame ~/ 8) * 1000 * bitrate ~/ sampleRate + padding;

    return (
      version: version,
      layer: layer,
      bitrate: bitrate,
      sampleRate: sampleRate,
      mono: (data[i + 3] >> 6) == 3,
      crc: (data[i + 1] & 0x1) == 0,
      length: length,
      samplesPerFrame: samplesPerFrame,
    );
  }

  int _getSampleRate(int version, int sampleRateIndex) {
    final sampleRates = [
      [44100, 48000, 32000],
      [22050, 24000, 16000],
      [11025, 12000, 8000],
    ];

    int versionIndex = version == 3 ? 0 : (version == 2 ? 1 : 2);
    return sampleRateIndex < 3 ? sampleRates[versionIndex][sampleRateIndex] : 0;
  }

  void _setDurationMetadata(Duration duration) {
    setMetadata('duration', duration.inMilliseconds);
  }

  /// Splits the given [data] into a list of sublists based on null terminators.
  ///
  /// The function iterates through the [data] starting from index [start].
  /// It finds the next null terminator based on the specified [encoding].
  /// It then adds the sublist from [start] to the null terminator to the [result] list.
  /// The function continues this process until it has iterated through the entire [data].
  ///
  /// Parameters:
  /// - [data]: The input data to be split.
  /// - [start]: The starting index for splitting.
  /// - [encoding]: The encoding of the data (0: ISO-8859-1, 1: UTF-16 with BOM, 2: UTF-16 without BOM, 3: UTF-8).
  ///
  /// Returns:
  /// A list of sublists, where each sublist represents a part of the [data] split by null terminators.
  List<Uint8List> _splitNullTerminated(Uint8List data, int encoding) {
    List<Uint8List> result = [];
    int start = 0;
    while (start < data.length) {
      int end = _findNullTerminator(data, start, encoding);
      result.add(data.sublist(start, end));
      start = end + (encoding == 1 || encoding == 2 ? 2 : 1);
    }
    return result;
  }

  /// Finds the index of the next null terminator in the given [data] starting from [start].
  ///
  /// The function supports different encoding types:
  /// - 0: ISO-8859-1
  /// - 1: UTF-16 with BOM
  /// - 2: UTF-16 without BOM
  /// - 3: UTF-8
  ///
  /// Parameters:
  /// - data: The input data to search for the null terminator.
  /// - start: The starting index for searching.
  /// - encoding: The encoding type of the data.
  ///
  /// Returns:
  /// The index of the next null terminator in the [data], or the length of the [data] if no null terminator is found.
  int _findNullTerminator(Uint8List data, int start, int encoding) {
    if (encoding == 1 || encoding == 2) {
      for (int i = start; i < data.length - 1; i += 2) {
        if (data[i] == 0 && data[i + 1] == 0) return i;
      }
    } else {
      // The last string of a frame does not have to be terminated.
      final end = data.indexOf(0, start);
      return end == -1 ? data.length : end;
    }
    return data.length;
  }

  /// Removes unsynchronization bytes from the given [data].
  ///
  /// Unsynchronization bytes are used in ID3v2 tags to prevent the parser from
  /// interpreting data as a new frame. This function removes these bytes from the
  /// [data] to ensure accurate parsing.
  ///
  /// Parameters:
  /// - [data]: The input data from which to remove unsynchronization bytes.
  ///
  /// Returns:
  /// A new [Uint8List] containing the [data] with unsynchronization bytes removed.
  Uint8List _removeUnsynchronization(Uint8List data) {
    final result = BytesBuilder(copy: false);
    for (var i = 0; i < data.length; i++) {
      result.addByte(data[i]);
      if (data[i] == 0xFF && i + 1 < data.length && data[i + 1] == 0x00) {
        i++;
      }
    }
    return result.takeBytes();
  }

  /// Whether [data] has to be unsynchronized: a 0xFF byte that is followed by
  /// 0x00, by a byte that has the top three bits set (which looks like the
  /// start of an MPEG frame), or by nothing.
  bool _needsUnsynchronization(Uint8List data) {
    for (var i = 0; i < data.length; i++) {
      if (data[i] != 0xFF) continue;
      if (i + 1 == data.length || data[i + 1] == 0x00 || data[i + 1] >= 0xE0) {
        return true;
      }
    }
    return false;
  }

  /// Inserts a 0x00 byte after every 0xFF that [_needsUnsynchronization]
  /// looks for.
  Uint8List _unsynchronize(Uint8List data) {
    final result = BytesBuilder(copy: false);
    for (var i = 0; i < data.length; i++) {
      result.addByte(data[i]);
      if (data[i] == 0xFF &&
          (i + 1 == data.length ||
              data[i + 1] == 0x00 ||
              data[i + 1] >= 0xE0)) {
        result.addByte(0x00);
      }
    }
    return result.takeBytes();
  }

  /// Decodes a string from the given [data] using the specified [encoding].
  ///
  /// The [encoding] parameter can have the following values:
  /// - 0: ISO-8859-1 encoding
  /// - 1: UTF-16 encoding with BOM
  /// - 2: UTF-16 encoding without BOM
  /// - 3: UTF-8 encoding
  ///
  /// The function returns the decoded string.
  ///
  /// If the [encoding] is not recognized, the function defaults to ISO-8859-1 encoding.
  ///
  /// Parameters:
  /// - [data]: The input data to decode.
  /// - [encoding]: The encoding type of the input data.
  ///
  /// Returns:
  /// The decoded string.
  String _decodeString(Uint8List data, int encoding) {
    switch (encoding) {
      case 0:
        return latin1.decode(data);
      case 1:
        return _decodeUTF16(data);
      case 2:
        return String.fromCharCodes(data);
      case 3:
        return utf8.decode(data);
      default:
        return latin1.decode(data);
    }
  }

  /// Converts the given 4-byte [data] into a single integer using the sync-safe integer encoding.
  ///
  /// The sync-safe integer encoding is used in ID3v2 tags to prevent the parser from interpreting data as a new frame.
  ///
  /// The function shifts the bytes of the [data] to the left by the appropriate number of bits and then performs a bitwise OR operation.
  ///
  /// Parameters:
  /// - [data]: A [Uint8List] containing the 4-byte data to be converted.
  ///
  /// Returns:
  /// - An [int] representing the converted sync-safe integer.
  int _syncSafeInteger(Uint8List data) {
    return (data[0] << 21) | (data[1] << 14) | (data[2] << 7) | data[3];
  }

  /// Parses the ID3v1 tag from the end of the file.
  ///
  /// The function reads the last 128 bytes of the file and checks if they contain an ID3v1 tag.
  /// If an ID3v1 tag is found, the function extracts and stores the metadata (title, artist, album, year, track, comment, and genre) from the tag.
  void _parseID3v1() {
    if (file.lengthSync() < 128) return;
    file.setPositionSync(file.lengthSync() - 128);
    Uint8List tagData = file.readSync(128);

    // Check if the first three bytes of the tagData are 'TAG'
    if (String.fromCharCodes(tagData.sublist(0, 3)) == 'TAG') {
      logger.i('Found ID3v1 tag');

      // ID3v2 is more complete (ID3v1 cuts text off at 30 characters), so
      // ID3v1 only fills in what the ID3v2 tag did not have.
      void fill(String key, dynamic value) {
        if (value == null || (value is String && value.isEmpty)) return;
        if (!metadata.contains(key)) setMetadata(key, value);
      }

      String text(int start, int end) =>
          _trimNullTerminator(_decodeString(tagData.sublist(start, end), 0));

      fill('title', text(3, 33));
      fill('artist', text(33, 63));
      fill('album', text(63, 93));
      fill('year', text(93, 97));

      // Check for ID3v1.1 (looking for a zero byte at position 125)
      if (tagData[125] == 0) {
        fill('track', tagData[126] == 0 ? null : tagData[126]);
        fill('comment', text(97, 125));
      } else {
        fill('comment', text(97, 127));
      }

      // 255 means that there is no genre.
      fill('genre', tagData[127] == 255 ? null : getGenreById(tagData[127]));
    }
  }

  /// Trims the null terminator from the given string.
  ///
  /// If the input string contains a null terminator ('\x00'), this function will
  /// return a substring up to the null terminator. If the input string does not
  /// contain a null terminator, the function will return the entire input string.
  ///
  /// Parameters:
  /// - [input]: The input string to trim.
  ///
  /// Returns:
  /// A string with the null terminator removed, or the entire input string if
  /// no null terminator was found.
  String _trimNullTerminator(String input) {
    int nullIndex = input.indexOf('\x00');
    return nullIndex != -1 ? input.substring(0, nullIndex) : input;
  }

  /// Parses the APEv2 tag from the end of the file.
  ///
  /// The function reads the last 32 bytes of the file and checks if they contain an APEv2 tag.
  /// If an APEv2 tag is found, the function extracts and stores the metadata (key-value pairs) from the tag.
  ///
  /// If an error occurs during parsing, the function logs the error message.
  void _parseAPEv2() {
    try {
      file.setPositionSync(file.lengthSync() - 32);
      Uint8List footer = file.readSync(32);

      // Check if the first eight bytes of the tagData are 'APETAGEX'
      if (String.fromCharCodes(footer.sublist(0, 8)) == 'APETAGEX') {
        int size = ByteData.view(footer.buffer).getUint32(12, Endian.little);
        int itemCount = ByteData.view(
          footer.buffer,
        ).getUint32(16, Endian.little);

        file.setPositionSync(file.lengthSync() - size - 32);
        Uint8List tagData = file.readSync(size);

        int offset = 0;
        for (int i = 0; i < itemCount; i++) {
          Uint8List itemHeader = tagData.sublist(offset, offset + 8);
          int valueLength = ByteData.view(
            itemHeader.buffer,
          ).getUint32(0, Endian.little);
          int flags = ByteData.view(
            itemHeader.buffer,
          ).getUint32(4, Endian.little);

          int keyEnd = tagData.indexOf(0, offset + 8);
          String key = utf8.decode(tagData.sublist(offset + 8, keyEnd));
          Uint8List value = tagData.sublist(
            keyEnd + 1,
            keyEnd + 1 + valueLength,
          );

          if ((flags & 0x01) != 0) {
            // Text item
            setMetadata(key.toLowerCase(), utf8.decode(value));
          } else {
            // Binary item
            setMetadata(key.toLowerCase(), value);
          }

          offset = keyEnd + 1 + valueLength;
        }
      }
    } catch (e) {
      logger.w('Error parsing APEv2 tag: $e');
    }
  }

  /// Parses the Vorbis comments from the Ogg stream.
  ///
  /// This function reads the Ogg stream from the current position and extracts the
  /// Vorbis comments. The comments are then stored in the metadata map.
  ///
  /// If an error occurs during parsing, the error message is logged using the logger.
  void _parseVorbisComments() {
    try {
      file.setPositionSync(0);
      Uint8List header = file.readSync(4);
      if (String.fromCharCodes(header) == 'OggS') {
        // Find the second Ogg page (which typically contains Vorbis comments)
        _findSecondOggPage();
        Uint8List pageHeader = file.readSync(27);
        int segmentCount = pageHeader[26];
        Uint8List segmentTable = file.readSync(segmentCount);
        int packetSize = segmentTable.reduce((a, b) => a + b);

        Uint8List packet = file.readSync(packetSize);
        if (packet[0] == 3) {
          // Vorbis comment packet type
          int vendorLength = ByteData.view(
            packet.buffer,
          ).getUint32(7, Endian.little);
          int commentListLength = ByteData.view(
            packet.buffer,
          ).getUint32(11 + vendorLength, Endian.little);

          int offset = 15 + vendorLength;
          for (int i = 0; i < commentListLength; i++) {
            int commentLength = ByteData.view(
              packet.buffer,
            ).getUint32(offset, Endian.little);
            Uint8List commentData = packet.sublist(
              offset + 4,
              offset + 4 + commentLength,
            );
            String comment = utf8.decode(commentData);
            List<String> parts = comment.split('=');
            if (parts.length == 2) {
              setMetadata(parts[0].toLowerCase(), parts[1]);
            }
            offset += 4 + commentLength;
          }
        }
      }
    } catch (e) {
      logger.w('Error parsing Vorbis comments: $e');
    }
  }

  /// Finds the second Ogg page in the file.
  ///
  /// This function reads the Ogg stream from the current position and searches for
  /// the second Ogg page. If the second Ogg page is found, the file position is
  /// updated to the start of the second page. If the second Ogg page is not found,
  /// an exception is thrown.
  ///
  /// @throws Exception if the second Ogg page is not found.
  void _findSecondOggPage() {
    int pageCount = 0;
    while (pageCount < 2) {
      Uint8List signature = file.readSync(4);
      if (String.fromCharCodes(signature) != 'OggS') {
        throw Exception('Invalid Ogg stream');
      }
      Uint8List header = file.readSync(23);
      int pageSegments = header[22];
      Uint8List segmentTable = file.readSync(pageSegments);
      int pageSize = segmentTable.reduce((a, b) => a + b);
      if (pageCount == 1) {
        file.setPositionSync(file.positionSync() - 27);
        return;
      }
      file.setPositionSync(file.positionSync() + pageSize);
      pageCount++;
    }
  }

  /// Writes the file, with the current frames, to [outputPath].
  ///
  /// The new ID3v2 tag replaces the original one and everything after it
  /// (audio, ID3v1 and APE tags) is copied unchanged.
  @override
  Future<void> writeToFile(String outputPath) =>
      _writeWithFrames(outputPath, _id3v2Tag.frames);

  /// The ID3v2 version used when writing: the version of the existing tag if
  /// it is 2.3, otherwise 2.4.
  int get _writeVersion => _id3v2Tag.version == 3 ? 3 : 4;

  /// How many bytes of padding follow a tag that is written to a new file, so
  /// that later edits that grow the tag a little still fit.
  static const int tagPadding = 1024;

  /// The frames of the tag as bytes, with the tag header flags that go with
  /// them. Parts that look like the start of an MPEG frame are
  /// unsynchronized: in ID3v2.4 each frame on its own (and flagged as such),
  /// in ID3v2.3 the tag as a whole.
  ({Uint8List body, int flags}) _buildTag(List<ID3v2Frame> frames) {
    final version = _writeVersion;
    final tag = BytesBuilder(copy: false);

    for (final frame in frames) {
      var data = frame.data;
      var flags = frame.flags;
      if (version == 4 &&
          (flags & 0x0002) == 0 &&
          _needsUnsynchronization(data)) {
        data = _unsynchronize(data);
        flags |= 0x0002;
      }

      final header = ByteData(10);
      for (var i = 0; i < 4; i++) {
        header.setUint8(i, frame.id.codeUnitAt(i));
      }
      if (version == 4) {
        header.buffer.asUint8List().setRange(
          4,
          8,
          _getSyncSafeBytes(data.length),
        );
      } else {
        header.setUint32(4, data.length, Endian.big);
      }
      header.setUint16(8, flags, Endian.big);
      tag.add(header.buffer.asUint8List());
      tag.add(data);
    }

    var body = tag.takeBytes();
    var tagFlags = 0;
    if (version == 3 && _needsUnsynchronization(body)) {
      body = _unsynchronize(body);
      tagFlags = 0x80;
    }
    return (body: body, flags: tagFlags);
  }

  Uint8List _tagHeader(int flags, int size) => Uint8List.fromList([
    0x49, 0x44, 0x33, // 'ID3'
    _writeVersion, 0x00, // version and revision
    flags, // no extended header or footer
    ..._getSyncSafeBytes(size),
  ]);

  /// Writes the file with [frames] as its ID3v2 tag, to a new file.
  ///
  /// If the file has an ID3v1 tag, the fields named in [changes] (a map of
  /// friendly key to new value, `null` for a removed key) are updated in it so
  /// that it does not contradict the new ID3v2 tag. Its other fields are kept.
  Future<void> _writeWithFrames(
    String outputPath,
    List<ID3v2Frame> frames, {
    Map<String, dynamic> changes = const {},
  }) async {
    final tag = _buildTag(frames);

    final input = File(file.path).openSync(mode: FileMode.read);
    final output = File(outputPath).openSync(mode: FileMode.write);
    try {
      output.writeFromSync(_tagHeader(tag.flags, tag.body.length + tagPadding));
      output.writeFromSync(tag.body);
      output.writeFromSync(Uint8List(tagPadding));

      final length = input.lengthSync();
      final start = math.min(_audioStart, length);

      // An ID3v1 tag is the last 128 bytes of the file.
      var audioEnd = length;
      Uint8List? id3v1;
      if (length - 128 >= start) {
        input.setPositionSync(length - 128);
        final tail = input.readSync(128);
        if (tail[0] == 0x54 && tail[1] == 0x41 && tail[2] == 0x47) {
          id3v1 = tail;
          audioEnd = length - 128;
        }
      }

      await input.setPosition(start);
      final buffer = Uint8List(1024 * 1024);
      var remaining = audioEnd - start;
      while (remaining > 0) {
        final bytesRead = await input.readInto(
          buffer,
          0,
          math.min(remaining, buffer.length),
        );
        if (bytesRead == 0) {
          throw ID3Exception('Unexpected end of file while copying audio');
        }
        await output.writeFrom(buffer, 0, bytesRead);
        remaining -= bytesRead;
      }

      if (id3v1 != null) {
        output.writeFromSync(_patchedId3v1(id3v1, changes));
      }
    } finally {
      input.closeSync();
      output.closeSync();
    }

    logger.d('File written successfully to: $outputPath');
  }

  /// Replaces the ID3v2 tag in the file itself, without touching the audio,
  /// when the new tag fits in the space the old tag (with its padding) took.
  /// The rest of that space becomes padding. Returns `false`, having changed
  /// nothing, when there is no tag yet or the new one is too big.
  bool _writeInPlace(List<ID3v2Frame> frames, Map<String, dynamic> changes) {
    if (_audioStart == 0) return false;

    final tag = _buildTag(frames);
    final room = _audioStart - 10;
    if (tag.body.length > room) return false;

    final output = File(file.path).openSync(mode: FileMode.append);
    try {
      output.setPositionSync(0);
      output.writeFromSync(_tagHeader(tag.flags, room));
      output.writeFromSync(tag.body);
      output.writeFromSync(Uint8List(room - tag.body.length));

      final length = output.lengthSync();
      if (changes.isNotEmpty && length - 128 >= _audioStart) {
        output.setPositionSync(length - 128);
        final tail = output.readSync(128);
        if (tail[0] == 0x54 && tail[1] == 0x41 && tail[2] == 0x47) {
          output.setPositionSync(length - 128);
          output.writeFromSync(_patchedId3v1(tail, changes));
        }
      }
      output.flushSync();
    } finally {
      output.closeSync();
    }
    return true;
  }

  /// Returns a copy of the ID3v1 tag [original] with the fields named in
  /// [changes] replaced.
  Uint8List _patchedId3v1(Uint8List original, Map<String, dynamic> changes) {
    final tag = Uint8List.fromList(original);

    void setField(String key, int offset, int length) {
      if (!changes.containsKey(key)) return;
      // ID3v1 is ISO-8859-1, so anything outside it becomes '?'.
      final text = _id3v1Text(
        changes[key],
      ).replaceAll(RegExp(r'[^\u0000-ÿ]'), '?');
      final bytes = latin1.encode(text);
      tag.fillRange(offset, offset + length, 0);
      tag.setRange(offset, offset + math.min(length, bytes.length), bytes);
    }

    // ID3v1.1 keeps the track number in the last byte of the comment.
    final hasTrack = changes.containsKey('track')
        ? _id3v1Track(changes['track']) != null
        : tag[125] == 0 && tag[126] != 0;

    setField('title', 3, 30);
    setField('artist', 33, 30);
    setField('album', 63, 30);
    setField('year', 93, 4);
    setField('comment', 97, hasTrack ? 28 : 30);

    if (changes.containsKey('track')) {
      final track = _id3v1Track(changes['track']);
      tag[125] = 0;
      tag[126] = track ?? 0;
    }

    if (changes.containsKey('genre')) {
      final name = _id3v1Text(changes['genre']).toLowerCase();
      final index = genres.indexWhere((genre) => genre.toLowerCase() == name);
      tag[127] = index >= 0 && index < 255 ? index : 255;
    }

    return tag;
  }

  String _id3v1Text(dynamic value) {
    if (value == null) return '';
    if (value is Map) return value['text']?.toString() ?? '';
    return _textFromValue(value, 4) ?? value.toString();
  }

  int? _id3v1Track(dynamic value) {
    final first = value is List
        ? (value.isEmpty ? null : value.first)
        : value is String
        ? int.tryParse(value.split('/').first.trim())
        : value;
    return first is int && first > 0 && first <= 255 ? first : null;
  }

  /// The frame ID and, for frames that can occur several times, the part of
  /// the key after the colon (`TXXX:Mood` is the TXXX frame described as
  /// "Mood"), for the friendly [key].
  ///
  /// `TYER` was dropped in ID3v2.4, where the year lives in `TDRC`.
  ({String id, String? qualifier}) _frameTarget(String key, int version) {
    if (key.length > 5 && key[4] == ':') {
      return (id: key.substring(0, 4), qualifier: key.substring(5));
    }
    if (key == 'userDefinedText') return (id: 'TXXX', qualifier: null);
    // The keys that reading uses for chapters and tables of contents.
    if (key.startsWith('chapter_')) {
      return (id: 'CHAP', qualifier: key.substring('chapter_'.length));
    }
    if (key.startsWith('tableOfContents_')) {
      return (id: 'CTOC', qualifier: key.substring('tableOfContents_'.length));
    }
    if (key == 'year' && version == 4) return (id: 'TDRC', qualifier: null);
    return (id: _friendlyToFrameIds[key] ?? key, qualifier: null);
  }

  /// What tells frames with the same ID apart: the description of a TXXX
  /// or WXXX frame, the owner of a POPM frame and the element ID of a CHAP or
  /// CTOC frame. `null` for other frames.
  String? _frameIdentity(ID3v2Frame frame) {
    final data = frame.data;
    try {
      if (frame.id == 'CHAP' || frame.id == 'CTOC') {
        final end = data.indexOf(0);
        return latin1.decode(data.sublist(0, end == -1 ? data.length : end));
      }
      if ((frame.id == 'TXXX' || frame.id == 'WXXX') && data.length > 1) {
        final description = _splitNullTerminated(data.sublist(1), data[0]);
        return description.isEmpty
            ? ''
            : _decodeString(description[0], data[0]);
      }
      if (frame.id == 'POPM') {
        final end = data.indexOf(0);
        return latin1.decode(data.sublist(0, end == -1 ? data.length : end));
      }
    } catch (e) {
      logger.w('Could not read the identity of ${frame.id}: $e');
    }
    return null;
  }

  /// Encodes the given metadata [value] into an ID3v2 frame with the specified [key].
  ///
  /// Returns `null` (and logs a warning) if the key is not a valid frame ID
  /// or the value cannot be encoded for that frame. If the value needs
  /// several frames (a list of pictures), only the first is returned.
  ID3v2Frame? encodeMetadataFrame(String key, dynamic value) =>
      _encodeFrames(key, value)?.first;

  List<ID3v2Frame>? _encodeFrames(String key, dynamic value) {
    final version = _writeVersion;
    final target = _frameTarget(key, version);

    if (!RegExp(r'^[A-Z0-9]{4}$').hasMatch(target.id)) {
      logger.w('Not a valid ID3v2 frame ID: ${target.id} (from key: $key)');
      return null;
    }

    final bodies = _encodeBodies(target, value, version);
    if (bodies == null || bodies.isEmpty) {
      logger.w('Failed to encode metadata for key: $key');
      return null;
    }

    return [
      for (final body in bodies) ID3v2Frame(target.id, body.length, body),
    ];
  }

  /// Encodes [strings] in one text encoding suitable for [version].
  ///
  /// ID3v2.4 uses UTF-8. ID3v2.3 has no UTF-8, so the text is ISO-8859-1 when
  /// it fits and UTF-16 with a byte order mark otherwise. With [preferLatin1]
  /// ISO-8859-1 is used whenever it fits, in either version.
  ({int encoding, List<Uint8List> parts}) _encodeStrings(
    List<String> strings,
    int version, {
    bool preferLatin1 = false,
  }) {
    final fitsLatin1 = strings.every(
      (s) => s.codeUnits.every((c) => c <= 0xFF),
    );

    if (fitsLatin1 && (version == 3 || preferLatin1)) {
      return (
        encoding: 0,
        parts: [for (final s in strings) Uint8List.fromList(latin1.encode(s))],
      );
    }
    if (version == 4) {
      return (
        encoding: 3,
        parts: [for (final s in strings) Uint8List.fromList(utf8.encode(s))],
      );
    }
    return (
      encoding: 1,
      parts: [
        for (final s in strings)
          Uint8List.fromList([
            0xFF, 0xFE, // byte order mark: little-endian
            for (final unit in s.codeUnits) ...[unit & 0xFF, unit >> 8],
          ]),
      ],
    );
  }

  /// The terminator of a string in the given text [encoding].
  List<int> _terminator(int encoding) => encoding == 1 ? [0, 0] : [0];

  /// Turns [value] into the text stored in a text frame, or `null` if the
  /// value has no text form.
  String? _textFromValue(dynamic value, int version) {
    if (value is String) return value;
    if (value is int) return value.toString();
    if (value is bool) return value ? '1' : '0';
    if (value is List<int> && value.length == 2) {
      // Number pairs such as track or disc: "number/total".
      return value[1] > 0 ? '${value[0]}/${value[1]}' : '${value[0]}';
    }
    if (value is List<String>) {
      return value.join(version == 4 ? '\x00' : '/');
    }
    return null;
  }

  /// Encodes [value] as the body (or bodies) of the frame [target].
  List<Uint8List>? _encodeBodies(
    ({String id, String? qualifier}) target,
    dynamic value,
    int version,
  ) {
    final id = target.id;

    if (id == 'APIC') {
      final pictures = value is Uint8List || value is Map
          ? [value]
          : value is List
          ? value
          : null;
      if (pictures == null) return null;
      final bodies = [for (final p in pictures) _encodePictureFrame(p)];
      return bodies.contains(null) ? null : bodies.cast<Uint8List>();
    }

    if (value is Uint8List) {
      // Raw frame body for frames without a dedicated encoder.
      return [value];
    }

    if (id == 'COMM' || id == 'USLT') {
      final fields = value is Map
          ? value
          : value is String
          ? {'text': value}
          : null;
      if (fields == null) return null;
      final language = (fields['language'] ?? 'eng').toString();
      if (language.length != 3 || language.codeUnits.any((c) => c > 0x7F)) {
        return null;
      }
      final strings = _encodeStrings([
        (fields['description'] ?? '').toString(),
        (fields['text'] ?? '').toString(),
      ], version);
      return [
        Uint8List.fromList([
          strings.encoding,
          ...ascii.encode(language),
          ...strings.parts[0],
          ..._terminator(strings.encoding),
          ...strings.parts[1],
        ]),
      ];
    }

    if (id == 'TXXX') {
      final fields = value is Map ? value : {'value': value};
      final description =
          target.qualifier ?? fields['description']?.toString() ?? '';
      final text = _textFromValue(fields['value'], version);
      if (text == null) return null;
      final strings = _encodeStrings([description, text], version);
      return [
        Uint8List.fromList([
          strings.encoding,
          ...strings.parts[0],
          ..._terminator(strings.encoding),
          ...strings.parts[1],
        ]),
      ];
    }

    if (id == 'POPM') {
      // A rating from 0 to 255, or {email, rating, counter}.
      final fields = value is Map ? value : {'rating': value};
      final rating = fields['rating'];
      final counter = fields['counter'] ?? 0;
      final email = (fields['email'] ?? '').toString();
      if (rating is! int || rating < 0 || rating > 255) return null;
      if (counter is! int || counter < 0 || counter > 0xFFFFFFFF) return null;
      if (email.codeUnits.any((c) => c > 0xFF)) return null;
      return [
        Uint8List.fromList([
          ...latin1.encode(email),
          0,
          rating,
          ...intToBytes(counter, 4),
        ]),
      ];
    }

    if (id == 'WXXX') {
      // A description and a URL: {description, url}, or just the URL.
      final fields = value is Map ? value : {'url': value};
      final description =
          target.qualifier ?? (fields['description'] ?? '').toString();
      final url = fields['url'];
      if (url is! String || url.codeUnits.any((c) => c > 0xFF)) return null;
      final strings = _encodeStrings([description], version);
      return [
        Uint8List.fromList([
          strings.encoding,
          ...strings.parts[0],
          ..._terminator(strings.encoding),
          ...latin1.encode(url), // always ISO-8859-1
        ]),
      ];
    }

    if (id == 'SYLT') {
      // The shape that reading produces: language, timeStampFormat (1 is MPEG
      // frames, 2 is milliseconds), contentType (1 is lyrics), description and
      // lyrics, a list of {timeStamp, text}.
      if (value is! Map) return null;
      final lines = value['lyrics'];
      if (lines is! List || lines.isEmpty) return null;
      final language = (value['language'] ?? 'eng').toString();
      final format = value['timeStampFormat'] ?? 2;
      final contentType = value['contentType'] ?? 1;
      if (language.length != 3 || language.codeUnits.any((c) => c > 0x7F)) {
        return null;
      }
      if (format is! int || format < 1 || format > 2) return null;
      if (contentType is! int || contentType < 0 || contentType > 255) {
        return null;
      }

      final times = <int>[];
      final texts = <String>[(value['description'] ?? '').toString()];
      for (final line in lines) {
        final time = line is Map ? line['timeStamp'] : null;
        final text = line is Map ? line['text'] : null;
        if (time is! int || time < 0 || time > 0xFFFFFFFF || text is! String) {
          return null;
        }
        times.add(time);
        texts.add(text);
      }

      final strings = _encodeStrings(texts, version);
      final terminator = _terminator(strings.encoding);
      return [
        Uint8List.fromList([
          strings.encoding,
          ...ascii.encode(language),
          format,
          contentType,
          ...strings.parts[0],
          ...terminator,
          for (var i = 0; i < times.length; i++) ...[
            ...strings.parts[i + 1],
            ...terminator,
            ...intToBytes(times[i], 4),
          ],
        ]),
      ];
    }

    if (id == 'CHAP') {
      // The shape that reading produces: elementId, startTime and endTime in
      // milliseconds, startOffset and endOffset (0xFFFFFFFF when unused), and
      // text sub-frames. `title` is a shorthand for the TIT2 sub-frame.
      if (value is! Map) return null;
      final elementId = _elementId(target.qualifier ?? value['elementId']);
      final subFrames = _subFrames(value, version);
      if (elementId == null || subFrames == null) return null;

      final numbers = <int>[];
      for (final entry in {
        'startTime': 0,
        'endTime': 0,
        'startOffset': 0xFFFFFFFF,
        'endOffset': 0xFFFFFFFF,
      }.entries) {
        final number = value[entry.key] ?? entry.value;
        if (number is! int || number < 0 || number > 0xFFFFFFFF) return null;
        numbers.add(number);
      }
      return [
        Uint8List.fromList([
          ...elementId,
          0,
          for (final number in numbers) ...intToBytes(number, 4),
          ...subFrames,
        ]),
      ];
    }

    if (id == 'CTOC') {
      // elementId, children (a list of element IDs), isOrdered, isTopLevel and
      // text sub-frames.
      if (value is! Map) return null;
      final elementId = _elementId(target.qualifier ?? value['elementId']);
      final subFrames = _subFrames(value, version);
      final children = value['children'] ?? <String>[];
      if (elementId == null || subFrames == null) return null;
      if (children is! List || children.length > 255) return null;

      final childIds = [for (final child in children) _elementId(child)];
      if (childIds.contains(null)) return null;
      final ordered = value['isOrdered'] == true ? 0x01 : 0;
      final topLevel = value['isTopLevel'] == true ? 0x02 : 0;
      return [
        Uint8List.fromList([
          ...elementId,
          0,
          ordered | topLevel,
          childIds.length,
          for (final child in childIds) ...[...child!, 0],
          ...subFrames,
        ]),
      ];
    }

    if (id.startsWith('W') && id != 'WXXX') {
      // URL frames are plain ISO-8859-1 with no encoding byte.
      return value is String
          ? [Uint8List.fromList(latin1.encode(value))]
          : null;
    }

    if (id.startsWith('T')) {
      final text = _textFromValue(value, version);
      if (text == null) return null;
      final strings = _encodeStrings([text], version);
      return [
        Uint8List.fromList([strings.encoding, ...strings.parts[0]]),
      ];
    }

    return null;
  }

  /// An element ID of a chapter or table of contents frame as bytes, or
  /// `null` if it is empty, not text or has characters ISO-8859-1 cannot hold.
  List<int>? _elementId(dynamic id) {
    if (id is! String || id.isEmpty) return null;
    if (id.codeUnits.any((c) => c == 0 || c > 0xFF)) return null;
    return latin1.encode(id);
  }

  /// The text sub-frames of a chapter or table of contents frame, as bytes,
  /// from the `subFrames` map (frame ID to text) and `title` (a shorthand for
  /// `TIT2`) of [fields]. Returns `null` if they are not valid.
  List<int>? _subFrames(Map fields, int version) {
    final texts = <String, String>{};
    final given = fields['subFrames'];
    if (given is Map) {
      for (final entry in given.entries) {
        if (entry.key is! String || entry.value is! String) return null;
        texts[entry.key as String] = entry.value as String;
      }
    } else if (given != null) {
      return null;
    }
    final title = fields['title'];
    if (title is String) {
      texts['TIT2'] = title;
    } else if (title != null) {
      return null;
    }

    final bytes = <int>[];
    for (final entry in texts.entries) {
      if (!RegExp(r'^T[A-Z0-9]{3}$').hasMatch(entry.key) ||
          entry.key == 'TXXX') {
        return null;
      }
      final strings = _encodeStrings([entry.value], version);
      final body = [strings.encoding, ...strings.parts[0]];
      bytes.addAll([
        ...ascii.encode(entry.key),
        ...(version == 4
            ? _getSyncSafeBytes(body.length)
            : intToBytes(body.length, 4)),
        0, 0, // flags
        ...body,
      ]);
    }
    return bytes;
  }

  /// Encodes a picture, given as image bytes or as a map in the shape that
  /// reading produces: `data` and optionally `mimeType`, `pictureType` and
  /// `description`.
  Uint8List? _encodePictureFrame(dynamic picture) {
    final fields = picture is Map ? picture : {'data': picture};
    final data = fields['data'];
    if (data is! Uint8List) return null;

    final mimeType = (fields['mimeType'] ?? _getMimeType(data)).toString();
    final pictureType = fields['pictureType'] ?? 3; // 3 is the front cover
    final description = (fields['description'] ?? 'Cover').toString();
    if (pictureType is! int || pictureType < 0 || pictureType > 20) return null;
    if (mimeType.codeUnits.any((c) => c > 0x7F)) return null;

    final strings = _encodeStrings(
      [description],
      _writeVersion,
      preferLatin1: true,
    );
    return Uint8List.fromList([
      strings.encoding,
      ...ascii.encode(mimeType),
      0x00,
      pictureType,
      ...strings.parts[0],
      ..._terminator(strings.encoding),
      ...data,
    ]);
  }

  String _getMimeType(Uint8List imageData) {
    if (imageData.length > 3) {
      if (imageData[0] == 0xFF && imageData[1] == 0xD8) {
        return 'image/jpeg';
      } else if (imageData[0] == 0x89 && imageData[1] == 0x50) {
        return 'image/png';
      } else if (imageData[0] == 0x47 &&
          imageData[1] == 0x49 &&
          imageData[2] == 0x46) {
        return 'image/gif';
      }
    }
    return 'image/jpeg';
  }

  /// Applies the queued operations and rewrites the file.
  ///
  /// Setting a key replaces every frame with that ID, and removing a key
  /// removes them all. The exceptions are `TXXX` and `POPM` frames, which are
  /// told apart by their description and owner: `TXXX:Mood` sets the user text
  /// frame described as "Mood" and leaves the others alone. If the file has an
  /// ID3v1 tag, the fields that were changed are updated in it too. The file
  /// is only replaced once the new one has been written completely, so a
  /// failure leaves the original untouched.
  ///
  /// If the new tag fits in the space of the old one (the tag plus its
  /// padding) and [inPlace] is true, only the tag is overwritten and the audio
  /// is not copied, which is much faster for big files. A failure of the disk
  /// half way through that write could then leave a damaged tag; pass
  /// `inPlace: false` to always write a new file and rename it instead. A tag
  /// that has to grow is always written to a new file, with
  /// [tagPadding] bytes of padding.
  ///
  /// Throws an [ID3Exception] if a value cannot be encoded or the file cannot
  /// be written.
  @override
  Future<void> applyMetadataChanges({bool inPlace = true}) async {
    if (pendingOperations.isEmpty) {
      logger.i('No pending metadata operations to apply.');
      return;
    }

    final frames = List<ID3v2Frame>.of(_id3v2Tag.frames);
    final changes = <String, dynamic>{};
    final operations = List<MetadataOperation>.of(pendingOperations);
    for (final operation in operations) {
      switch (operation.type) {
        case OperationType.add:
          // Adding a picture keeps the pictures that are already there.
          if (_frameTarget(operation.key, _writeVersion).id == 'APIC') {
            _appendFrames(frames, operation.key, operation.value);
          } else {
            _addOrUpdateFrames(frames, operation.key, operation.value);
          }
          changes[operation.key] = operation.value;
          break;
        case OperationType.update:
          _addOrUpdateFrames(frames, operation.key, operation.value);
          changes[operation.key] = operation.value;
          break;
        case OperationType.remove:
          _removeFrames(frames, operation.key);
          changes[operation.key] = null;
          break;
      }
    }

    try {
      if (!inPlace || !_writeInPlace(frames, changes)) {
        await _safeWrite(frames, changes);
      }
    } catch (e) {
      throw ID3Exception('Failed to apply metadata changes: $e');
    }

    // Operations queued while the file was being written stay queued.
    pendingOperations.removeWhere(operations.contains);
    parseMetadata(); // Rebuild the metadata and tag from the new file
  }

  void _addOrUpdateFrames(List<ID3v2Frame> frames, String key, dynamic value) {
    final encoded = _encodeFrames(key, value);
    if (encoded == null) {
      throw ID3Exception('Failed to encode metadata for key: $key');
    }

    final id = encoded.first.id;
    final identity = _frameIdentity(encoded.first);
    bool replaced(ID3v2Frame frame) =>
        frame.id == id &&
        (identity == null || _frameIdentity(frame) == identity);

    final index = frames.indexWhere(replaced);
    frames.removeWhere(replaced);
    // Keep the frame where it was so the tag order stays stable.
    frames.insertAll(index == -1 ? frames.length : index, encoded);
  }

  void _appendFrames(List<ID3v2Frame> frames, String key, dynamic value) {
    final encoded = _encodeFrames(key, value);
    if (encoded == null) {
      throw ID3Exception('Failed to encode metadata for key: $key');
    }
    frames.addAll(encoded);
  }

  void _removeFrames(List<ID3v2Frame> frames, String key) {
    final target = _frameTarget(key, _writeVersion);
    // A rating belongs to the owner without an e-mail address.
    final identity = target.id == 'POPM' ? '' : target.qualifier;
    frames.removeWhere(
      (frame) =>
          frame.id == target.id &&
          (identity == null || _frameIdentity(frame) == identity),
    );
  }

  /// Writes the updated file next to the original and renames it over the
  /// original, so the original is never half-written.
  Future<void> _safeWrite(
    List<ID3v2Frame> frames,
    Map<String, dynamic> changes,
  ) async {
    final path = file.path;
    final tempFile = File('$path.tmp');
    try {
      await _writeWithFrames(tempFile.path, frames, changes: changes);
      await tempFile.rename(path);
    } catch (e) {
      logger.e('Error during file write: $e');
      if (tempFile.existsSync()) tempFile.deleteSync();
      rethrow;
    }
  }

  List<int> _getSyncSafeBytes(int value) {
    return [
      (value >> 21) & 0x7F,
      (value >> 14) & 0x7F,
      (value >> 7) & 0x7F,
      value & 0x7F,
    ];
  }
}
