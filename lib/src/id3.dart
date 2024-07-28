import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'genres.dart';
import 'id3tags.dart';
import 'utils.dart';
import 'handler.dart';

class ID3Exception implements Exception {
  final String message;
  ID3Exception(this.message);

  @override
  String toString() => 'ID3Exception: $message';
}

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

class ID3Handler extends CodecHandler {
  late ID3v2Tag _id3v2Tag;
  final Map<String, Function> _customFrameHandlers = {};
  final Map<String, List<Map<String, dynamic>>> _groupedFrames = {};

  ID3Handler(super.filePath) {
    parseMetadata();
  }

  void registerCustomFrameHandler(String frameId, Function handler) {
    _customFrameHandlers[frameId] = handler;
  }

  @override
  void parseMetadata() {
    openRead();
    try {
      _id3v2Tag = _parseID3v2();
      _parseID3v1();
      _parseAPEv2();
      _parseVorbisComments();
    } catch (e) {
      logger.w('Error parsing metadata: $e');
    } finally {
      close();
    }
  }

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

      return ID3v2Tag(version, revision, flags, size, frames);
    } else {
      logger.w('No ID3v2 tag found');
      return ID3v2Tag(0, 0, 0, 0, []);
    }
  }

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
        ID3v2Frame frame = ID3v2Frame(frameId, frameSize, frameData);
        _parseID3v2Frame(frame, frameFlags, version);
        frames.add(frame);
      } catch (e) {
        logger.w('Error parsing frame $frameId: $e');
      }

      offset += 10 + frameSize;
    }

    return frames;
  }

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

  void _parsePrivateFrame(Uint8List data) {
    int ownerIdEnd = data.indexOf(0);
    String ownerId = String.fromCharCodes(data.sublist(0, ownerIdEnd));
    var privateData = data.sublist(ownerIdEnd + 1);
    setMetadata('private_$ownerId', privateData);
  }

  void _parseTextFrame(String frameId, Uint8List data) {
    String text = _decodeTextFrame(data);
    String key = _frameIdToKey(frameId);
    if (frameId == 'TRCK') {
      // Handle track number / total tracks
      List<String> parts = text.split('/');
      setMetadata('trackNumber', int.tryParse(parts[0].trim()));
      if (parts.length > 1) {
        setMetadata('totalTracks', int.tryParse(parts[1].trim()));
      }
    } else if (text.contains('\x00')) {
      setMetadata(key, text.split('\x00'));
    } else {
      setMetadata(key, text);
    }
  }

  void _parseUserDefinedTextFrame(Uint8List data) {
    int encoding = data[0];
    List<Uint8List> parts = _splitNullTerminated(data.sublist(1), encoding);
    if (parts.length >= 2) {
      String description = _decodeString(parts[0], encoding);
      String value = _decodeString(parts[1], encoding);
      setMetadata(
          'userDefinedText', {'description': description, 'value': value});
    }
  }

  String _decodeTextFrame(Uint8List data) {
    if (data.isEmpty) return '';
    int encoding = data[0];
    Uint8List textData = data.sublist(1);

    switch (encoding) {
      case 0: // ISO-8859-1
        return latin1.decode(textData).trim();
      case 1: // UTF-16 with BOM
        return _decodeUTF16(textData);
      case 2: // UTF-16BE without BOM
        return String.fromCharCodes(textData).trim();
      case 3: // UTF-8
        return utf8.decode(textData).trim();
      default:
        logger.w('Unknown text encoding: $encoding');
        return latin1.decode(textData).trim();
    }
  }

  String _decodeUTF16(Uint8List data) {
    if (data.length < 2) return '';
    Uint8List bom = data.sublist(0, 2);
    if (bom[0] == 0xFF && bom[1] == 0xFE) {
      return String.fromCharCodes(data.sublist(2).buffer.asUint16List()).trim();
    } else if (bom[0] == 0xFE && bom[1] == 0xFF) {
      return String.fromCharCodes(data.sublist(2).buffer.asUint16List()).trim();
    } else {
      return String.fromCharCodes(data).trim();
    }
  }

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

  void _parseAPICFrame(Uint8List data) {
    int encoding = data[0];
    int mimeTypeEnd = data.indexOf(0, 1);
    String mimeType = latin1.decode(data.sublist(1, mimeTypeEnd));
    int pictureType = data[mimeTypeEnd + 1];
    int descriptionEnd = _findNullTerminator(data, mimeTypeEnd + 2, encoding);
    String description =
        _decodeString(data.sublist(mimeTypeEnd + 2, descriptionEnd), encoding);
    Uint8List pictureData = data.sublist(descriptionEnd);
    setMetadata('picture', {
      'mimeType': mimeType,
      'pictureType': pictureType,
      'description': description,
      'data': pictureData,
    });
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

  int _syncSafeInteger(Uint8List data) {
    return (data[0] << 21) | (data[1] << 14) | (data[2] << 7) | data[3];
  }

  void _parseID3v1() {
    file.setPositionSync(file.lengthSync() - 128);
    Uint8List tagData = file.readSync(128);
    if (String.fromCharCodes(tagData.sublist(0, 3)) == 'TAG') {
      logger.i('Found ID3v1 tag');
      setMetadata('title',
          _trimNullTerminator(_decodeString(tagData.sublist(3, 33), 0)));
      setMetadata('artist',
          _trimNullTerminator(_decodeString(tagData.sublist(33, 63), 0)));
      setMetadata('album',
          _trimNullTerminator(_decodeString(tagData.sublist(63, 93), 0)));
      setMetadata('year',
          _trimNullTerminator(_decodeString(tagData.sublist(93, 97), 0)));

      // Check for ID3v1.1 (looking for a zero byte at position 125)
      if (tagData[125] == 0) {
        setMetadata('track', tagData[126]);
        setMetadata('comment',
            _trimNullTerminator(_decodeString(tagData.sublist(97, 125), 0)));
      } else {
        setMetadata('comment',
            _trimNullTerminator(_decodeString(tagData.sublist(97, 127), 0)));
      }

      setMetadata('genre', getGenreById(tagData[127]));
    }
  }

  String _trimNullTerminator(String input) {
    int nullIndex = input.indexOf('\x00');
    return nullIndex != -1 ? input.substring(0, nullIndex) : input;
  }

  void _parseAPEv2() {
    try {
      file.setPositionSync(file.lengthSync() - 32);
      Uint8List footer = file.readSync(32);
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

  @override
  Future<void> writeToFile(String outputPath) async {
    final outputFile = await File(outputPath).open(mode: FileMode.write);

    try {
      await _writeID3v2Tag(outputFile);
      await _copyAudioData(outputFile);
      await _writeID3v1Tag(outputFile);
    } finally {
      outputFile.closeSync();
    }

    logger.d('File written successfully to: $outputPath');
  }

  Future<void> _writeID3v2Tag(RandomAccessFile outputFile) async {
    outputFile.setPositionSync(0);
    outputFile.writeFromSync(utf8.encode('ID3'));
    outputFile.writeFromSync([0x04, 0x00, 0x00]); // Version and flags

    int sizePosition = outputFile.positionSync();
    outputFile.writeFromSync([0x00, 0x00, 0x00, 0x00]); // Placeholder for size

    int startPosition = outputFile.positionSync();

    for (var frame in _id3v2Tag.frames) {
      await _writeFrame(outputFile, frame);
    }

    int endPosition = outputFile.positionSync();
    int tagSize = endPosition - startPosition;

    outputFile.setPositionSync(sizePosition);
    outputFile.writeFromSync(_getSyncSafeBytes(tagSize));
    outputFile.setPositionSync(endPosition);
  }

  Future<void> _writeFrame(
    RandomAccessFile outputFile,
    ID3v2Frame frame,
  ) async {
    outputFile.writeFromSync(utf8.encode(frame.id));
    outputFile.writeFromSync(_getSyncSafeBytes(frame.size));
    outputFile.writeFromSync([0x00, 0x00]); // Frame flags
    outputFile.writeFromSync(frame.data);
  }

  Future<void> _copyAudioData(RandomAccessFile outputFile) async {
    openRead();
    file.setPositionSync(_id3v2Tag.size);
    outputFile.setPositionSync(outputFile.lengthSync());

    final bufferSize = 5 * 1024 * 1024; // 5 MB buffer
    var buffer = Uint8List(bufferSize);
    int bytesRead;

    while ((bytesRead = file.readIntoSync(buffer)) > 0) {
      outputFile.writeFromSync(buffer.sublist(0, bytesRead));
    }
    close();
  }

  Future<void> _writeID3v1Tag(RandomAccessFile outputFile) async {
    outputFile.setPositionSync(outputFile.lengthSync());
    outputFile.writeFromSync(utf8.encode('TAG'));

    // Write title (30 bytes)
    String title = getMetadata<String>('title') ?? '';
    outputFile.writeFromSync(_padOrTruncate(title, 30));

    // Write artist (30 bytes)
    String artist = getMetadata<String>('artist') ?? '';
    outputFile.writeFromSync(_padOrTruncate(artist, 30));

    // Write album (30 bytes)
    String album = getMetadata<String>('album') ?? '';
    outputFile.writeFromSync(_padOrTruncate(album, 30));

    // Write year (4 bytes)
    String year = getMetadata<String>('year') ?? '';
    outputFile.writeFromSync(_padOrTruncate(year, 4));

    // Write comment (28 or 30 bytes)
    String comment = getMetadata<String>('comment') ?? '';
    int? track = getMetadata<int>('track');
    if (track != null) {
      // ID3v1.1 format (with track number)
      outputFile.writeFromSync(_padOrTruncate(comment, 28));
      outputFile.writeFromSync([0, track]);
    } else {
      // ID3v1.0 format
      outputFile.writeFromSync(_padOrTruncate(comment, 30));
    }

    // Write genre (1 byte)
    String genre = getMetadata<String>('genre') ?? '';
    int genreId = genres.indexOf(genre);
    outputFile.writeFromSync([genreId >= 0 ? genreId : 255]);
  }

  ID3v2Frame? encodeMetadataFrame(String key, dynamic value) {
    final frameId = _friendlyToFrameIds[key] ?? key;
    final encodedValue = _encodeMetadataValue(key, value);

    if (encodedValue == null) {
      logger.w('Failed to encode metadata for key: $key');
      return null;
    }

    final frameData = Uint8List.fromList(encodedValue);
    return ID3v2Frame(frameId, frameData.length, frameData);
  }

  Uint8List _padOrTruncate(String text, int length) {
    if (text.length > length) {
      return Uint8List.fromList(utf8.encode(text.substring(0, length)));
    } else {
      return Uint8List.fromList(utf8.encode(text).padRight(length, 0));
    }
  }

  Uint8List? _encodeMetadataValue(String key, dynamic value) {
    if (value is String) {
      return Uint8List.fromList([
        0x03,
        ...utf8.encode(value),
      ]); // UTF-8 encoding
    } else if (value is int) {
      return Uint8List.fromList([
        0x00,
        ...intToBytes(value, 4),
      ]); // ISO-8859-1 encoding
    } else if (value is bool) {
      return Uint8List.fromList([
        0x00,
        value ? 1 : 0,
      ]); // ISO-8859-1 encoding
    } else if (value is List<int> && value.length == 2) {
      // For numeric pairs like track number or disk number
      return Uint8List.fromList([
        0x00,
        ...value.expand((i) => intToBytes(i, 2))
      ]); // ISO-8859-1 encoding
    } else if (value is Uint8List && key == 'picture') {
      // Handle artwork (APIC frame)
      String mimeType = _getMimeType(value);
      return Uint8List.fromList([
        0x00, // Text encoding (ISO-8859-1)
        ...ascii.encode('$mimeType\0'), // MIME type
        0x03, // Picture type (0x03 = front cover)
        ...ascii.encode('Cover\0'), // Description
        ...value // Picture data
      ]);
    } else {
      logger.w(
        'Unsupported metadata value type: ${value.runtimeType} for key: $key',
      );
      return null;
    }
  }

  String _getMimeType(Uint8List imageData) {
    if (imageData.length > 2) {
      if (imageData[0] == 0xFF && imageData[1] == 0xD8) {
        return 'image/jpeg';
      } else if (imageData[0] == 0x89 && imageData[1] == 0x50) {
        return 'image/png';
      }
    }
    return 'image/unknown';
  }

  @override
  Future<void> applyMetadataChanges() async {
    if (pendingOperations.isEmpty) {
      logger.i('No pending metadata operations to apply.');
      return;
    }

    for (MetadataOperation operation in pendingOperations) {
      switch (operation.type) {
        case OperationType.add:
        case OperationType.update:
          _addOrUpdateMetadata(operation.key, operation.value);
          break;
        case OperationType.remove:
          _removeMetadata(operation.key);
          break;
      }
    }

    _updateTagSize();

    try {
      await _safeWriteUpdatedTag();
      pendingOperations.clear();
      parseMetadata(); // Reopen the file and rebuild the ID3 tag
    } catch (e) {
      throw ID3Exception('Failed to apply metadata changes: $e');
    }
  }

  void _addOrUpdateMetadata(String key, dynamic value) {
    final frameId = _friendlyToFrameIds[key] ?? key;
    final encodedFrame = encodeMetadataFrame(key, value);

    if (encodedFrame == null) {
      throw ID3Exception('Failed to encode metadata for key: $key');
    }

    int existingIndex =
        _id3v2Tag.frames.indexWhere((frame) => frame.id == frameId);
    if (existingIndex != -1) {
      _id3v2Tag.frames[existingIndex] = encodedFrame;
    } else {
      _id3v2Tag.frames.add(encodedFrame);
    }
  }

  void _removeMetadata(String key) {
    final frameId = _friendlyToFrameIds[key] ?? key;
    _id3v2Tag.frames.removeWhere((frame) => frame.id == frameId);
  }

  void _updateTagSize() {
    _id3v2Tag.size =
        _id3v2Tag.frames.fold(10, (sum, frame) => sum + frame.size + 10);
  }

  Future<void> _safeWriteUpdatedTag() async {
    final tempDir = await Directory.systemTemp.createTemp('id3_update_');
    final tempFile = File('${tempDir.path}/temp_id3');
    final backupFile = File('${file.path}.bak');

    try {
      // Write to temporary file
      await writeToFile(tempFile.path);

      // Create a backup of the original file
      await File(file.path).copy(backupFile.path);

      // Replace the original file with the temporary file
      await tempFile.copy(file.path);

      // If everything succeeded, delete the backup and temp files
      await backupFile.delete();
      await tempFile.delete();
      await tempDir.delete();
    } catch (e) {
      logger.e('Error during file write: $e');

      // If backup exists, restore it
      if (await backupFile.exists()) {
        await backupFile.copy(file.path);
        await backupFile.delete();
      }

      // Clean up temp files
      if (await tempFile.exists()) await tempFile.delete();
      if (await tempDir.exists()) await tempDir.delete();

      throw ID3Exception('Failed to write updated ID3 tag: $e');
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
