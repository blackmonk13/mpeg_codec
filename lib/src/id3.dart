import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'handler.dart';

class ID3v2Tag {
  int version;
  int revision;
  int flags;
  int size;
  List<ID3v2Frame> frames;

  ID3v2Tag(this.version, this.revision, this.flags, this.size, this.frames);
}

class ID3v2Frame {
  String id;
  int size;
  Uint8List data;

  ID3v2Frame(this.id, this.size, this.data);
}

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
  'year': 'TYER',
  'track': 'TRCK',
  'genre': 'TCON',
  'comment': 'COMM',
  'picture': 'APIC',
  // Add more mappings as needed
};

class ID3Handler extends CodecHandler {
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
      _parseID3v2();
      _parseID3v1();
      _parseAPEv2();
      _parseVorbisComments();
    } catch (e) {
      logger.w('Error parsing metadata: $e');
    } finally {
      close();
    }
  }

  void _parseID3v2() {
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

      _parseID3v2Frames(tagData.sublist(dataOffset), version);

      if (footerPresent) {
        _parseID3v2Footer(tagData.sublist(tagData.length - 10));
      }
    } else {
      logger.w('No ID3v2 tag found');
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

  void _parseID3v2Frames(Uint8List data, int version) {
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
        _parseID3v2Frame(frameId, frameData, frameFlags, version);
      } catch (e) {
        logger.w('Error parsing frame $frameId: $e');
      }

      offset += 10 + frameSize;
    }

    // Process grouped frames after parsing all frames
    _processGroupedFrames();
  }

  void _parseID3v2Frame(
    String frameId,
    Uint8List frameData,
    int frameFlags,
    int version,
  ) {
    bool dataLengthIndicator = (frameFlags & 0x0001) != 0;
    bool compressed = (frameFlags & 0x0008) != 0;
    bool encrypted = (frameFlags & 0x0004) != 0;
    bool grouped = (frameFlags & 0x0040) != 0;

    if (encrypted) {
      logger.w('Encrypted frames are not supported: $frameId');
      return;
    }

    int dataOffset = dataLengthIndicator ? 4 : 0;
    Uint8List decompressedData = frameData.sublist(dataOffset);

    if (compressed) {
      try {
        int decompressedSize = _syncSafeInteger(frameData.sublist(0, 4));
        decompressedData =
            Uint8List.fromList(ZLibDecoder().decodeBytes(decompressedData));
        if (decompressedData.length != decompressedSize) {
          logger.w('Decompressed size mismatch for frame $frameId');
        }
      } catch (e) {
        logger.e('Error decompressing frame $frameId: $e');
        return;
      }
    }

    if (grouped) {
      _handleGroupedFrame(frameId, decompressedData, version);
      return;
    }

    if (_customFrameHandlers.containsKey(frameId)) {
      _customFrameHandlers[frameId]!(decompressedData, version);
      return;
    }

    switch (frameId) {
      case 'TIT2':
      case 'TPE1':
      case 'TPE2':
      case 'TALB':
      case 'TYER':
      case 'TDRC':
      case 'TCON':
      case 'TRCK':
        _parseTextFrame(frameId, decompressedData);
        break;
      case 'TXXX':
        _parseUserDefinedTextFrame(decompressedData);
        break;
      case 'COMM':
        _parseCommentFrame(decompressedData);
        break;
      case 'APIC':
        _parseAPICFrame(decompressedData);
        break;
      case 'USLT':
        _parseUnsynchronizedLyricsFrame(decompressedData);
        break;
      case 'SYLT':
        _parseSynchronizedLyricsFrame(decompressedData, version);
        break;
      case 'CHAP':
        _parseChapterFrame(decompressedData, version);
        break;
      case 'CTOC':
        _parseTableOfContentsFrame(decompressedData, version);
        break;
      case 'PRIV':
        _parsePrivateFrame(decompressedData);
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

  void _processGroupedFrames() {
    _groupedFrames.forEach((frameId, frames) {
      frames.sort((a, b) => a['groupId'].compareTo(b['groupId']));
      var combinedData = frames
          .map((frame) => frame['data'] as Uint8List)
          .reduce((a, b) => Uint8List.fromList([...a, ...b]));
      _parseID3v2Frame(
          frameId, combinedData, 0, 4); // Assume version 4 for grouped frames
    });
    _groupedFrames.clear();
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

  String _frameIdToKey(String frameId) {
    switch (frameId) {
      case 'TIT2':
        return 'title';
      case 'TPE1':
        return 'artist';
      case 'TPE2':
        return 'albumArtist';
      case 'TALB':
        return 'album';
      case 'TYER':
        return 'year';
      case 'TDRC':
        return 'recordingTime';
      case 'TCON':
        return 'genre';
      case 'TRCK':
        return 'track';
      default:
        return frameId.toLowerCase();
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
    // To be implemented
    throw UnimplementedError();
  }

  @override
  Future<void> applyMetadataChanges() async {
    // To be implemented
    throw UnimplementedError();
  }
}
