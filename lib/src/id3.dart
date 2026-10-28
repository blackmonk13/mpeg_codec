import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math' as math;

import 'package:archive/archive.dart';

import 'exceptions.dart';
import 'genres.dart';
import 'id3_tags.dart';
import 'utils.dart';
import 'handler.dart';

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
  'rating': 'POPM',
  'replayGain': 'RVA2',
};

String _frameIdToKey(String frameId) {
  return _friendlyToFrameIds.entries
      .firstWhere((entry) => entry.value == frameId,
          orElse: () => MapEntry(frameId.toLowerCase(), frameId))
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

  /// A map of custom frame handlers for handling unknown or unsupported frames.
  final Map<String, Function> _customFrameHandlers = {};

  /// A map of grouped frames, used for storing frames that are part of a group.
  final Map<String, List<Map<String, dynamic>>> _groupedFrames = {};

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
      if (unsynchronization) {
        tagData = _removeUnsynchronization(tagData);
      }

      int dataOffset = 0;
      if (extendedHeader) {
        dataOffset = _parseExtendedHeader(tagData, version);
      }

      List<ID3v2Frame> frames =
          _parseID3v2Frames(tagData.sublist(dataOffset), version);

      if (footerPresent) {
        _parseID3v2Footer(tagData.sublist(tagData.length - 10));
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
      int frameFlags =
          ByteData.view(frameHeader.buffer).getUint16(8, Endian.big);

      if (frameId == '\x00\x00\x00\x00') break;

      if (offset + 10 + frameSize > data.length) {
        logger.w('Invalid frame size for $frameId');
        break;
      }

      var frameData = data.sublist(offset + 10, offset + 10 + frameSize);
      try {
        ID3v2Frame frame =
            ID3v2Frame(frameId, frameSize, frameData, flags: frameFlags);
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

    if (compressed) {
      try {
        int decompressedSize = _syncSafeInteger(frame.data.sublist(0, 4));
        decompressedData =
            Uint8List.fromList(ZLibDecoder().decodeBytes(decompressedData));
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
      case 'COMM':
        _parseCommentFrame(data);
        break;
      case 'APIC':
        _parseAPICFrame(data);
        break;
      case 'USLT':
        _parseUnsynchronizedLyricsFrame(data);
        break;
      case 'SYLT':
        _parseSynchronizedLyricsFrame(data, _id3v2Tag.version);
        break;
      case 'CHAP':
        _parseChapterFrame(data, _id3v2Tag.version);
        break;
      case 'CTOC':
        _parseTableOfContentsFrame(data, _id3v2Tag.version);
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

    _groupedFrames[frameId]!.add({
      'groupId': groupId,
      'data': frameData,
    });
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
    int encoding = data[0];
    String language = String.fromCharCodes(data.sublist(1, 4));
    int timeStampFormat = data[4];
    int contentType = data[5];
    var contentData = data.sublist(6);
    var parts = _splitNullTerminated(contentData, encoding);
    if (parts.length >= 2) {
      String description = _decodeString(parts[0], encoding);
      List<Map<String, dynamic>> syncedLyrics = [];
      var lyricsData = parts[1];
      int offset = 0;
      while (offset < lyricsData.length - 4) {
        int timeStamp =
            ByteData.view(lyricsData.buffer).getUint32(offset, Endian.big);
        offset += 4;
        int endOffset = lyricsData.indexOf(0, offset);
        if (endOffset == -1) endOffset = lyricsData.length;
        String text =
            _decodeString(lyricsData.sublist(offset, endOffset), encoding);
        syncedLyrics.add({'timeStamp': timeStamp, 'text': text});
        offset = endOffset + 1;
      }
      setMetadata('synchronizedLyrics', {
        'language': language,
        'timeStampFormat': timeStampFormat,
        'contentType': contentType,
        'description': description,
        'lyrics': syncedLyrics
      });
    }
  }

  /// Parses the ID3v2 chapter frame.
  ///
  /// This function extracts the chapter element ID, start and end times, start and end offsets,
  /// and sub-frames from the given [data] and [version]. It then sets the extracted information
  /// as metadata with the key 'chapter_{elementId}'.
  ///
  /// Parameters:
  /// - [data]: The byte data containing the chapter frame.
  /// - [version]: The version of the ID3v2 tag.
  void _parseChapterFrame(Uint8List data, int version) {
    int elementIdEnd = data.indexOf(0);
    String elementId = String.fromCharCodes(data.sublist(0, elementIdEnd));
    int startTime =
        ByteData.view(data.buffer).getUint32(elementIdEnd + 1, Endian.big);
    int endTime =
        ByteData.view(data.buffer).getUint32(elementIdEnd + 5, Endian.big);
    int startOffset =
        ByteData.view(data.buffer).getUint32(elementIdEnd + 9, Endian.big);
    int endOffset =
        ByteData.view(data.buffer).getUint32(elementIdEnd + 13, Endian.big);
    var subFrames = data.sublist(elementIdEnd + 17);
    Map<String, dynamic> chapterInfo = {
      'elementId': elementId,
      'startTime': startTime,
      'endTime': endTime,
      'startOffset': startOffset,
      'endOffset': endOffset,
      'subFrames': {}
    };
    _parseID3v2Frames(subFrames, version); // Parse sub-frames
    setMetadata('chapter_$elementId', chapterInfo);
  }

  /// Parses the ID3v2 table of contents (TOC) frame.
  ///
  /// This function extracts the element ID, flags, entry count, child IDs, and sub-frames from the given [data] and [version].
  /// It then sets the extracted information as metadata with the key 'tableOfContents_{elementId}'.
  ///
  /// Parameters:
  /// - [data]: The byte data containing the TOC frame.
  /// - [version]: The version of the ID3v2 tag.
  void _parseTableOfContentsFrame(Uint8List data, int version) {
    int elementIdEnd = data.indexOf(0);
    String elementId = String.fromCharCodes(data.sublist(0, elementIdEnd));
    int flags = data[elementIdEnd + 1];
    int entryCount = data[elementIdEnd + 2];
    List<String> children = [];
    int offset = elementIdEnd + 3;
    for (int i = 0; i < entryCount; i++) {
      int childIdEnd = data.indexOf(0, offset);
      String childId = String.fromCharCodes(data.sublist(offset, childIdEnd));
      children.add(childId);
      offset = childIdEnd + 1;
    }
    var subFrames = data.sublist(offset);
    Map<String, dynamic> tocInfo = {
      'elementId': elementId,
      'isOrdered': (flags & 0x01) != 0,
      'children': children,
      'subFrames': {}
    };
    _parseID3v2Frames(subFrames, version); // Parse sub-frames
    setMetadata('tableOfContents_$elementId', tocInfo);
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
    setMetadata(
      'genre',
      genreList.length == 1 ? genreList[0] : genreList,
    );
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
      setMetadata(
        'userDefinedText',
        {
          'description': description,
          'value': value,
        },
      );
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
              'Unknown text encoding: $encoding, falling back to ISO-8859-1');
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
    ByteData byteData = ByteData.view(data.buffer);

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

    setMetadata('picture', {
      'mimeType': mimeType,
      'pictureType': pictureType,
      'description': description,
      'data': pictureData,
    });
  }

  /// Parses the Unsynchronized Lyrics (USLT) frame data and sets the corresponding metadata.
  ///
  /// The USLT frame contains unsynchronized lyrics, such as lyrics that are not synchronized with the audio.
  /// This function decodes the USLT frame data using the specified encoding and sets the metadata accordingly.
  ///
  /// Parameters:
  /// - [data]: A [Uint8List] containing the USLT frame data.
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
    final bitrates = [
      [32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448],
      [32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384],
      [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320],
      [32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256],
      [8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160],
    ];

    int versionIndex = version == 3 ? 0 : 1;
    int layerIndex = 3 - layer;
    int bitRateArrayIndex = versionIndex * 3 + layerIndex;

    return bitrateIndex > 0 && bitrateIndex <= 14
        ? bitrates[bitRateArrayIndex][bitrateIndex - 1]
        : 0;
  }

  Duration? _calculateDuration() {
    try {
      file.setPositionSync(0);
      int fileSize = file.lengthSync();
      setMetadata('size', fileSize); // Add file size to metadata

      // Try to parse VBR headers first
      Duration? vbrDuration = _parseVBRHeader();
      if (vbrDuration != null) {
        _setDurationMetadata(vbrDuration);
        return vbrDuration;
      }

      // If VBR header not found, use sampling method
      // ignore: unused_local_variable
      int totalFrames = 0;
      int totalBitrate = 0;
      int samplesCount = 0;
      int sampleInterval = math.max(fileSize ~/ 1000,
          1000); // Sample every ~1000 bytes or every 1KB, whichever is larger

      for (int position = 0;
          position < fileSize - 10;
          position += sampleInterval) {
        file.setPositionSync(position);
        Uint8List header = file.readSync(4);

        // Look for MP3 frame sync
        if (header[0] == 0xFF && (header[1] & 0xE0) == 0xE0) {
          int version = (header[1] & 0x18) >> 3;
          int layer = (header[1] & 0x06) >> 1;
          int bitrate = _getBitrate(version, layer, header[2] >> 4);
          int sampleRate = _getSampleRate(version, (header[2] & 0x0C) >> 2);

          if (bitrate > 0 && sampleRate > 0) {
            totalFrames++;
            totalBitrate += bitrate;
            samplesCount++;
          }
        }
      }

      if (samplesCount > 0) {
        double avgBitrate = totalBitrate / samplesCount;
        double durationSeconds = (fileSize * 8) / (avgBitrate * 1000);
        Duration calculatedDuration =
            Duration(milliseconds: (durationSeconds * 1000).round());
        _setDurationMetadata(calculatedDuration);
        return calculatedDuration;
      }
    } catch (e) {
      logger.e('Error calculating duration: $e');
    }
    return null;
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

  Duration? _parseVBRHeader() {
    try {
      file.setPositionSync(0);
      Uint8List initialData = file.readSync(10);

      // Skip ID3v2 tag if present
      if (initialData
          .sublist(0, 3)
          .equals(Uint8List.fromList([0x49, 0x44, 0x33]))) {
        int tagSize = _syncSafeInteger(initialData.sublist(6, 10)) + 10;
        file.setPositionSync(tagSize);
        initialData = file.readSync(10);
      }

      // Find first MP3 frame
      int frameStart = 0;
      while (frameStart < initialData.length - 1) {
        if (initialData[frameStart] == 0xFF &&
            (initialData[frameStart + 1] & 0xE0) == 0xE0) {
          break;
        }
        frameStart++;
      }

      if (frameStart >= initialData.length - 1) {
        return null; // No MP3 frame found
      }

      file.setPositionSync(file.positionSync() - (10 - frameStart));
      Uint8List frameHeader = file.readSync(4);
      int version = (frameHeader[1] & 0x18) >> 3;
      // int layer = (frameHeader[1] & 0x06) >> 1;
      int sampleRate = _getSampleRate(version, (frameHeader[2] & 0x0C) >> 2);

      // Check for Xing/Info header
      file.setPositionSync(file.positionSync() + (version == 3 ? 32 : 17));
      Uint8List xingHeader = file.readSync(12);
      if (xingHeader
              .sublist(0, 4)
              .equals(Uint8List.fromList([0x58, 0x69, 0x6E, 0x67])) || // "Xing"
          xingHeader
              .sublist(0, 4)
              .equals(Uint8List.fromList([0x49, 0x6E, 0x66, 0x6F]))) {
        // "Info"
        int flags = ByteData.view(xingHeader.buffer).getUint32(4);
        int framesOffset = 8;
        if ((flags & 0x1) != 0) {
          // Frames field is present
          int totalFrames =
              ByteData.view(xingHeader.buffer).getUint32(framesOffset);
          double durationSeconds = totalFrames * 1152 / sampleRate;
          return Duration(milliseconds: (durationSeconds * 1000).round());
        }
      }

      // Check for VBRI header
      file.setPositionSync(file.positionSync() - 12 + 32);
      Uint8List vbriHeader = file.readSync(26);
      if (vbriHeader
          .sublist(0, 4)
          .equals(Uint8List.fromList([0x56, 0x42, 0x52, 0x49]))) {
        // "VBRI"
        int totalFrames = ByteData.view(vbriHeader.buffer).getUint32(14);
        double durationSeconds = totalFrames * 1152 / sampleRate;
        return Duration(milliseconds: (durationSeconds * 1000).round());
      }
    } catch (e) {
      logger.e('Error parsing VBR header: $e');
    }
    return null;
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
      return data.indexOf(0, start);
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
    ByteData result = ByteData(data.length);
    int writeIndex = 0;
    for (int i = 0; i < data.length - 1; i++) {
      result.setUint8(writeIndex++, data[i]);
      if (data[i] == 0xFF && data[i + 1] == 0x00) {
        i++;
      }
    }
    if (data.isNotEmpty) {
      result.setUint8(writeIndex++, data.last);
    }
    return result.buffer.asUint8List(0, writeIndex);
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
    file.setPositionSync(file.lengthSync() - 128);
    Uint8List tagData = file.readSync(128);

    // Check if the first three bytes of the tagData are 'TAG'
    if (String.fromCharCodes(tagData.sublist(0, 3)) == 'TAG') {
      logger.i('Found ID3v1 tag');

      // Extract and store the title metadata
      setMetadata('title',
          _trimNullTerminator(_decodeString(tagData.sublist(3, 33), 0)));

      // Extract and store the artist metadata
      setMetadata('artist',
          _trimNullTerminator(_decodeString(tagData.sublist(33, 63), 0)));

      // Extract and store the album metadata
      setMetadata('album',
          _trimNullTerminator(_decodeString(tagData.sublist(63, 93), 0)));

      // Extract and store the year metadata
      setMetadata('year',
          _trimNullTerminator(_decodeString(tagData.sublist(93, 97), 0)));

      // Check for ID3v1.1 (looking for a zero byte at position 125)
      if (tagData[125] == 0) {
        // Extract and store the track metadata
        setMetadata('track', tagData[126]);

        // Extract and store the comment metadata
        setMetadata('comment',
            _trimNullTerminator(_decodeString(tagData.sublist(97, 125), 0)));
      } else {
        // Extract and store the comment metadata
        setMetadata('comment',
            _trimNullTerminator(_decodeString(tagData.sublist(97, 127), 0)));
      }

      // Extract and store the genre metadata
      setMetadata('genre', getGenreById(tagData[127]));
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
        int itemCount =
            ByteData.view(footer.buffer).getUint32(16, Endian.little);

        file.setPositionSync(file.lengthSync() - size - 32);
        Uint8List tagData = file.readSync(size);

        int offset = 0;
        for (int i = 0; i < itemCount; i++) {
          Uint8List itemHeader = tagData.sublist(offset, offset + 8);
          int valueLength =
              ByteData.view(itemHeader.buffer).getUint32(0, Endian.little);
          int flags =
              ByteData.view(itemHeader.buffer).getUint32(4, Endian.little);

          int keyEnd = tagData.indexOf(0, offset + 8);
          String key = utf8.decode(tagData.sublist(offset + 8, keyEnd));
          Uint8List value =
              tagData.sublist(keyEnd + 1, keyEnd + 1 + valueLength);

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
          int vendorLength =
              ByteData.view(packet.buffer).getUint32(7, Endian.little);
          int commentListLength = ByteData.view(packet.buffer)
              .getUint32(11 + vendorLength, Endian.little);

          int offset = 15 + vendorLength;
          for (int i = 0; i < commentListLength; i++) {
            int commentLength =
                ByteData.view(packet.buffer).getUint32(offset, Endian.little);
            Uint8List commentData =
                packet.sublist(offset + 4, offset + 4 + commentLength);
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

  Future<void> _writeWithFrames(
    String outputPath,
    List<ID3v2Frame> frames,
  ) async {
    final version = _writeVersion;
    final tag = BytesBuilder(copy: false);

    for (final frame in frames) {
      final header = ByteData(10);
      for (var i = 0; i < 4; i++) {
        header.setUint8(i, frame.id.codeUnitAt(i));
      }
      if (version == 4) {
        header.buffer.asUint8List().setRange(
              4,
              8,
              _getSyncSafeBytes(frame.data.length),
            );
      } else {
        header.setUint32(4, frame.data.length, Endian.big);
      }
      header.setUint16(8, frame.flags, Endian.big);
      tag.add(header.buffer.asUint8List());
      tag.add(frame.data);
    }

    final tagBytes = tag.takeBytes();
    final tagHeader = Uint8List.fromList([
      0x49, 0x44, 0x33, // 'ID3'
      version, 0x00, // version and revision
      0x00, // flags: no unsynchronization, extended header or footer
      ..._getSyncSafeBytes(tagBytes.length),
    ]);

    final input = File(file.path).openSync(mode: FileMode.read);
    final output = File(outputPath).openSync(mode: FileMode.write);
    try {
      output.writeFromSync(tagHeader);
      output.writeFromSync(tagBytes);

      input.setPositionSync(math.min(_audioStart, input.lengthSync()));
      final buffer = Uint8List(1024 * 1024);
      int bytesRead;
      while ((bytesRead = input.readIntoSync(buffer)) > 0) {
        output.writeFromSync(buffer, 0, bytesRead);
      }
    } finally {
      input.closeSync();
      output.closeSync();
    }

    logger.d('File written successfully to: $outputPath');
  }

  /// Returns the ID3v2 frame ID for the friendly [key], or [key] itself when
  /// it is already a frame ID.
  ///
  /// `TYER` was dropped in ID3v2.4, where the year lives in `TDRC`.
  String _frameIdFor(String key, int version) {
    if (key == 'year' && version == 4) return 'TDRC';
    return _friendlyToFrameIds[key] ?? key;
  }

  /// Encodes the given metadata [value] into an ID3v2 frame with the specified [key].
  ///
  /// Returns `null` (and logs a warning) if the key is not a valid frame ID
  /// or the value cannot be encoded for that frame.
  ID3v2Frame? encodeMetadataFrame(String key, dynamic value) {
    final version = _writeVersion;
    final frameId = _frameIdFor(key, version);

    if (!RegExp(r'^[A-Z0-9]{4}$').hasMatch(frameId)) {
      logger.w('Not a valid ID3v2 frame ID: $frameId (from key: $key)');
      return null;
    }

    final encodedValue = _encodeMetadataValue(key, frameId, value, version);
    if (encodedValue == null) {
      logger.w('Failed to encode metadata for key: $key');
      return null;
    }

    return ID3v2Frame(frameId, encodedValue.length, encodedValue);
  }

  /// Encodes [text] for a frame of the given ID3v2 [version].
  ///
  /// ID3v2.4 uses UTF-8. ID3v2.3 has no UTF-8, so the text is ISO-8859-1 when
  /// it fits and UTF-16 with a byte order mark otherwise.
  ({int encoding, Uint8List bytes}) _encodeText(String text, int version) {
    if (version == 4) {
      return (encoding: 3, bytes: Uint8List.fromList(utf8.encode(text)));
    }
    if (text.codeUnits.every((c) => c <= 0xFF)) {
      return (encoding: 0, bytes: Uint8List.fromList(latin1.encode(text)));
    }
    final bytes = BytesBuilder()..add([0xFF, 0xFE]);
    for (final unit in text.codeUnits) {
      bytes.add([unit & 0xFF, unit >> 8]);
    }
    return (encoding: 1, bytes: bytes.takeBytes());
  }

  /// An empty string followed by its terminator, in the given text [encoding].
  List<int> _emptyTerminatedString(int encoding) =>
      encoding == 1 ? [0xFF, 0xFE, 0x00, 0x00] : [0x00];

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

  /// Encodes [value] as the body of the frame [frameId].
  Uint8List? _encodeMetadataValue(
    String key,
    String frameId,
    dynamic value,
    int version,
  ) {
    if (value is Uint8List && key == 'picture') {
      return _encodePictureFrame(value);
    }

    if (value is Uint8List) {
      // Raw frame body for frames without a dedicated encoder.
      return value;
    }

    if (frameId == 'COMM' || frameId == 'USLT') {
      if (value is! String) return null;
      final text = _encodeText(value, version);
      return Uint8List.fromList([
        text.encoding,
        ...ascii.encode('eng'),
        ..._emptyTerminatedString(text.encoding), // empty description
        ...text.bytes,
      ]);
    }

    if (frameId.startsWith('W') && frameId != 'WXXX') {
      // URL frames are plain ISO-8859-1 with no encoding byte.
      return value is String ? Uint8List.fromList(latin1.encode(value)) : null;
    }

    if (frameId.startsWith('T') && frameId != 'TXXX') {
      final textValue = _textFromValue(value, version);
      if (textValue == null) return null;
      final text = _encodeText(textValue, version);
      return Uint8List.fromList([text.encoding, ...text.bytes]);
    }

    return null;
  }

  Uint8List _encodePictureFrame(Uint8List picture) {
    return Uint8List.fromList([
      0x00, // text encoding (ISO-8859-1)
      ...ascii.encode(_getMimeType(picture)),
      0x00,
      0x03, // picture type: front cover
      ...ascii.encode('Cover'),
      0x00,
      ...picture,
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
  /// removes them all. The file is only replaced once the new one has been
  /// written completely, so a failure leaves the original untouched.
  ///
  /// Throws an [ID3Exception] if a value cannot be encoded or the file cannot
  /// be written.
  @override
  Future<void> applyMetadataChanges() async {
    if (pendingOperations.isEmpty) {
      logger.i('No pending metadata operations to apply.');
      return;
    }

    final frames = List<ID3v2Frame>.of(_id3v2Tag.frames);
    for (final operation in pendingOperations) {
      switch (operation.type) {
        case OperationType.add:
        case OperationType.update:
          _addOrUpdateFrame(frames, operation.key, operation.value);
          break;
        case OperationType.remove:
          final frameId = _frameIdFor(operation.key, _writeVersion);
          frames.removeWhere((frame) => frame.id == frameId);
          break;
      }
    }

    try {
      await _safeWrite(frames);
    } catch (e) {
      throw ID3Exception('Failed to apply metadata changes: $e');
    }

    pendingOperations.clear();
    parseMetadata(); // Rebuild the metadata and tag from the new file
  }

  void _addOrUpdateFrame(List<ID3v2Frame> frames, String key, dynamic value) {
    final encodedFrame = encodeMetadataFrame(key, value);
    if (encodedFrame == null) {
      throw ID3Exception('Failed to encode metadata for key: $key');
    }

    final index = frames.indexWhere((frame) => frame.id == encodedFrame.id);
    frames.removeWhere((frame) => frame.id == encodedFrame.id);
    // Keep the frame where it was so the tag order stays stable.
    frames.insert(index == -1 ? frames.length : index, encodedFrame);
  }

  /// Writes the updated file next to the original and renames it over the
  /// original, so the original is never half-written.
  Future<void> _safeWrite(List<ID3v2Frame> frames) async {
    final path = file.path;
    final tempFile = File('$path.tmp');
    try {
      await _writeWithFrames(tempFile.path, frames);
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
