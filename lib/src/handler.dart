import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:logger/logger.dart';

import 'atoms.dart';
import 'exceptions.dart';
import 'genres.dart';
import 'metadata.dart';

enum OperationType { add, update, remove }

class MetadataOperation {
  final OperationType type;
  final String key;
  final dynamic value;

  MetadataOperation(this.type, this.key, [this.value]);
}

class MP4Handler {
  late RandomAccessFile _file;
  late Atom _root;
  late String _filePath;
  final Logger _logger = Logger();
  final Metadata _metadata = Metadata();
  final List<MetadataOperation> _pendingOperations = [];

  static const Map<String, String> _friendlyToAtomNames = {
    'title': '©nam',
    'artist': '©ART',
    'album': '©alb',
    'year': '©day',
    'genre': '©gen',
    'composer': '©wrt',
    'lyrics': '©lyr',
    'comment': '©cmt',
    'grouping': '©grp',
    'albumArtist': 'aART',
    'trackNumber': 'trkn',
    'discNumber': 'disk',
    'bpm': 'tmpo',
    'compilation': 'cpil',
    'gapless': 'pgap',
    'cover': 'covr',
    'description': 'desc',
    'longDescription': 'ldes',
    'encodingTool': '©too',
    'copyright': 'cprt',
    'sortAlbum': 'soal',
    'sortAlbumArtist': 'soaa',
    'sortArtist': 'soar',
    'sortTitle': 'sonm',
    'sortComposer': 'soco',
    'movementCount': '©mvc',
    'movementIndex': '©mvi',
    'rating': 'rtng',
  };

  static final Map<String, String> _atomToFriendlyNames = Map.fromEntries(
      _friendlyToAtomNames.entries.map((e) => MapEntry(e.value, e.key)));

  static const List<String> _containerAtoms = [
    'moov',
    // 'trak',
    'mdia',
    'minf',
    'stbl',
    'udta',
    'meta',
    'ilst',
  ];

  MP4Handler(String filePath) {
    _filePath = filePath;
    _setup();
  }

  void _setup() {
    _openRead();
    _root = _buildAtomTree();
    printAtomTree(_root);
    _parseMetadata();
    close();
  }

  void _openRead() {
    _file = File(_filePath).openSync(mode: FileMode.read);
  }

  void _log(dynamic message) {
    _logger.d(message);
  }

  Atom _buildAtomTree() {
    final root = Atom('root', _file.lengthSync(), 0);
    _parseAtomRecursive(root, 0, _file.lengthSync());
    return root;
  }

  void printAtomTree(Atom atom, [String indent = '']) {
    print('$indent${atom.toString()}');
    for (var child in atom.children) {
      printAtomTree(child, '$indent  ');
    }
  }

  void _parseAtomRecursive(Atom parent, int start, int end) {
    int offset = start;
    while (offset < end) {
      _file.setPositionSync(offset);
      int size = _readInt32();
      final type = _readFourCC();

      if (size == 0) {
        // Atom extends to end of file
        size = end - offset;
      } else if (size == 1) {
        // 64-bit size
        _file.setPositionSync(offset + 8);
        size = _readInt64();
      }

      if (size < 8 || offset + size > end) {
        _logger.w(
          'Invalid atom size or overflow: $type, size: $size, offset: $offset',
        );
        break;
      }

      final atom = Atom(type, size, offset);
      parent.children.add(atom);

      _log('Parsed atom: $type, size: $size, offset: $offset');

      if (parent.type == 'ilst') {
        // Special handling for 'ilst' children
        _parseIlstChild(atom, offset + 8, offset + size);
      } else if (_containerAtoms.contains(type)) {
        int childStart = offset + 8;
        if (type == 'meta') {
          // Skip the extra 4 bytes in 'meta' atom
          childStart += 4;
          _file.setPositionSync(offset + 8);
          atom.data = _file.readSync(4); // Store the extra 4 bytes
        }
        _parseAtomRecursive(atom, childStart, offset + size);
      } else if (type != 'mdat') {
        // Read the data for atoms other than 'mdat'
        _file.setPositionSync(offset + 8);
        atom.data = _file.readSync(size - 8);
      }

      offset += size;
    }
  }

  void _parseIlstChild(Atom parent, int start, int end) {
    int offset = start;
    while (offset < end) {
      _file.setPositionSync(offset);
      int size = _readInt32();
      final type = _readFourCC();

      if (size < 8) {
        _log(
          'Invalid ilst child size or overflow: $type, size: $size, offset: $offset',
        );
        break;
      }

      final atom = Atom(type, size, offset);
      parent.children.add(atom);

      _log('Parsed ilst child: $type, size: $size, offset: $offset');

      // Read the data for all ilst children
      _file.setPositionSync(offset + 8);
      atom.data = _file.readSync(size - 8);

      offset += size;
    }
  }

  int _readInt32() {
    final buffer = _file.readSync(4);
    return buffer.buffer.asByteData().getUint32(0, Endian.big);
  }

  int _readInt64() {
    final buffer = _file.readSync(8);
    return buffer.buffer.asByteData().getUint64(0, Endian.big);
  }

  String _readFourCC() {
    final buffer = _file.readSync(4);
    return String.fromCharCodes(buffer);
  }

  void _parseMetadata() {
    final ftypAtom = _findAtom(_root, 'ftyp');
    _parseFtypAtom(ftypAtom);

    final moovAtom = _findAtom(_root, 'moov');
    if (moovAtom == null) {
      _log('moov atom not found');
      return;
    }

    final mvhdAtom = _findAtom(moovAtom, 'mvhd');
    _parseMvhdAtom(mvhdAtom);

    final udtaAtom = _findAtom(moovAtom, 'udta');
    if (udtaAtom == null) {
      _log('udta atom not found');
      return;
    }

    final metaAtom = _findAtom(udtaAtom, 'meta');
    if (metaAtom == null) {
      _log('meta atom not found');
      return;
    }

    final ilstAtom = _findAtom(metaAtom, 'ilst');
    if (ilstAtom == null) {
      _log('ilst atom not found');
      return;
    }

    for (final atom in ilstAtom.children) {
      _parseMetadataItem(atom);
    }
  }

  void _parseMetadataItem(Atom atom) {
    if (atom.type == '----') {
      _parseExtendedMetadata(atom);
      return;
    }

    if (atom.children.isEmpty) return;

    final dataAtom = _findAtom(atom, 'data');
    if (dataAtom == null ||
        dataAtom.data == null ||
        dataAtom.data!.length < 8) {
      _log('Invalid data atom for ${atom.type}');
      return;
    }

    final dataType = dataAtom.data![3]; // Changed from [0] to [3]
    final value = dataAtom.data!.sublist(8);

    final friendlyName = _atomToFriendlyNames[atom.type] ?? atom.type;

    switch (atom.type) {
      // Text metadata
      case '©nam':
      case '©ART':
      case '©alb':
      case '©day':
      case '©gen':
      case '©wrt':
      case '©lyr':
      case '©cmt':
      case '©grp':
      case 'aART':
      case 'desc':
      case 'ldes':
      case '©too':
      case 'cprt':
      case 'soal':
      case 'soaa':
      case 'soar':
      case 'sonm':
      case 'soco':
        _metadata.set(friendlyName, _decodeText(value, dataType));
        break;

      // Numeric metadata
      case 'trkn':
      case 'disk':
        _metadata.set(friendlyName, _decodeNumericPair(value));
        break;
      case 'tmpo':
      case '©mvc':
      case '©mvi':
      case 'rtng':
        _metadata.set(friendlyName, _decodeInt(value));
        break;
      case 'cpil':
      case 'pgap':
        _metadata.set(friendlyName, _decodeBool(value));
        break;

      // Special cases
      case 'gnre':
        _metadata.set(friendlyName, _decodeGenre(value));
        break;
      case 'covr':
        _metadata.set(friendlyName, value);
        break;

      default:
        _log('Unhandled metadata type: ${atom.type}');
    }
  }

  void _parseMvhdAtom(Atom? atom) {
    if (atom?.data == null) {
      _log('mvhd atom data not found');
      return;
    }

    final atomData = atom!.data!;
    final version = atomData[0];

    final actualData = atomData.sublist(4);
    // print(String.fromCharCodes(actualData));
    if (version == 1) {
      _metadata.set('creationTime', _decodeInt(actualData.sublist(4, 12)));
      _metadata.set('modificationTime', _decodeInt(actualData.sublist(12, 20)));
      _metadata.set('timescale', _decodeInt(actualData.sublist(20, 24)));
      _metadata.set('duration', _decodeInt(actualData.sublist(24)));
    } else {
      _metadata.set('creationTime', _decodeInt(actualData.sublist(4, 8)));
      _metadata.set('modificationTime', _decodeInt(actualData.sublist(8, 12)));
      _metadata.set('timescale', _decodeInt(actualData.sublist(12, 16)));
      _metadata.set('duration', _decodeInt(actualData.sublist(16)));
    }
  }

  void _parseFtypAtom(Atom? atom) {
    if (atom?.data == null) {
      _log('ftyp atom data not found');
      return;
    }

    final atomData = atom!.data!;
    _metadata.set('fileType', _decodeText(atomData.sublist(0, 4), 1));
    _metadata.set('fileTypeVersion',
        _decodeInteger(atomData.sublist(4, 8), signed: false));

    final compatibleBrands = <String>[];
    int offset = 8;
    while (offset < atomData.length) {
      compatibleBrands
          .add(_decodeText(atomData.sublist(offset, offset + 4), 1));
      offset += 4;
    }
    _metadata.set('compatibleBrands', compatibleBrands);
  }

  String _decodeText(Uint8List value, int dataType) {
    switch (dataType) {
      case 1: // UTF-8
      case 3: // UTF-8 sort order
        return utf8.decode(value);
      case 0: // UTF-16
      case 2: // UTF-16 sort order
        return String.fromCharCodes(value.buffer.asUint16List());
      default:
        return utf8.decode(value); // Default to UTF-8
    }
  }

  List<int> _decodeNumericPair(Uint8List value) {
    if (value.length >= 8) {
      final data = value.buffer.asByteData();
      return [data.getUint16(2), data.getUint16(4)];
    }
    return [0, 0];
  }

  bool _decodeBool(Uint8List value) {
    return value.isNotEmpty && value[0] == 1;
  }

  String _decodeGenre(Uint8List value) {
    if (value.length == 2) {
      final genreId = value[1];
      return _getGenreById(genreId);
    } else {
      // If it's not a numeric genre, it's likely a string
      return utf8.decode(value);
    }
  }

  String _getGenreById(int id) {
    if (id >= 0 && id < genres.length) {
      return genres[id];
    } else {
      return 'Unknown';
    }
  }

  void _parseExtendedMetadata(Atom atom) {
    if (atom.children.length != 3) return;

    final meanAtom = atom.children[0];
    final nameAtom = atom.children[1];
    final dataAtom = atom.children[2];

    if (meanAtom.type != 'mean' ||
        nameAtom.type != 'name' ||
        dataAtom.type != 'data') return;

    final meanString = utf8.decode(meanAtom.data!.sublist(4));
    final nameString = utf8.decode(nameAtom.data!.sublist(4));
    final key = '$meanString.$nameString';

    final dataType = dataAtom.data![3]; // Changed from [0] to [3]
    final value = dataAtom.data!.sublist(8);

    _metadata.set(key, _decodeByType(value, dataType));
  }

  dynamic _decodeByType(Uint8List value, int dataType) {
    switch (dataType) {
      case 1: // UTF-8 text
        return utf8.decode(value);
      case 0: // UTF-16 text
        return String.fromCharCodes(value.buffer.asUint16List());
      case 21: // Signed integer
        return _decodeInteger(value, signed: true);
      case 22: // Unsigned integer
        return _decodeInteger(value, signed: false);
      case 23: // Float 32
        return ByteData.view(value.buffer).getFloat32(0, Endian.big);
      case 24: // Float 64
        return ByteData.view(value.buffer).getFloat64(0, Endian.big);
      case 27: // Boolean
        return value[0] != 0;
      default:
        return value;
    }
  }

  int _decodeInt(Uint8List value) {
    if (value.length >= 4) {
      return value.buffer.asByteData().getUint32(0, Endian.big);
    }
    return 0;
  }

  int _decodeInteger(Uint8List value, {required bool signed}) {
    final data = ByteData.view(value.buffer);
    switch (value.length) {
      case 1:
        return signed ? data.getInt8(0) : data.getUint8(0);
      case 2:
        return signed
            ? data.getInt16(0, Endian.big)
            : data.getUint16(0, Endian.big);
      case 4:
        return signed
            ? data.getInt32(0, Endian.big)
            : data.getUint32(0, Endian.big);
      case 8:
        return signed
            ? data.getInt64(0, Endian.big)
            : data.getUint64(0, Endian.big);
      default:
        throw MP4Exception('Unsupported integer size: ${value.length}');
    }
  }

  // Getter methods
  Metadata get metadata => _metadata;

  bool addNode(List<String> path, Atom newNode) {
    if (path.isEmpty || path[0] != _root.type) {
      _log('Path must start with the root node type');
      return false;
    }

    Atom current = _root;
    for (int i = 1; i < path.length; i++) {
      if (i == path.length - 1) {
        current.addChild(newNode);
      } else {
        Atom? found = current.children.firstWhere(
          (node) => node.type == path[i],
          orElse: () {
            Atom newParent = Atom(path[i], 0, 0);
            current.addChild(newParent);
            return newParent;
          },
        );
        current = found;
      }
    }
    updateTreeSizes();
    updateTreeOffsets();
    return true;
  }

  bool replaceNode(List<String> path, Atom newNode) {
    if (path.isEmpty || path[0] != _root.type) {
      throw ArgumentError('Path must start with the root node type');
    }

    Atom? parent;
    Atom current = _root;
    for (int i = 1; i < path.length; i++) {
      parent = current;
      try {
        current = current.children.firstWhere((node) => node.type == path[i]);
      } catch (e) {
        _log('Node not found: ${path[i]}');
        return false;
      }
    }

    if (parent != null) {
      int index = parent.children.indexOf(current);
      // newNode.children = current.children;
      parent.children[index] = newNode;
      updateTreeSizes();
      updateTreeOffsets();
      return true;
    }

    return false;
  }

  void updateTreeSizes() {
    _updateNodeSize(_root, true);
  }

  void _updateNodeSize(Atom node, bool isFirstChild) {
    for (int i = 0; i < node.children.length; i++) {
      _updateNodeSize(node.children[i], i == 0);
    }
    node.updateSize();
  }

  void updateTreeOffsets() {
    _root.updateOffsets(0, true);
  }

  Future<void> writeToFile(String outputPath) async {
    final outputFile = File(outputPath).openSync(mode: FileMode.write);

    try {
      await _writeAtomRecursive(_root, outputFile, 0);
    } finally {
      outputFile.closeSync();
    }

    _log('File written successfully to: $outputPath');
  }

  Future<int> _writeAtomRecursive(
    Atom atom,
    RandomAccessFile outputFile,
    int offset,
  ) async {
    if (atom.type == 'root') {
      int newOffset = offset;
      for (var child in atom.children) {
        newOffset = await _writeAtomRecursive(child, outputFile, newOffset);
      }
      return newOffset;
    }

    outputFile.setPositionSync(offset);
    outputFile.writeFromSync(_intToBytes(atom.size, 4));
    outputFile.writeFromSync(atom.type.codeUnits);

    int dataOffset = offset + 8;
    if (atom.type == 'meta') {
      // Write 4 null bytes for 'meta' atom
      outputFile.writeFromSync(Uint8List(4));
      dataOffset += 4;
    }

    if (atom.type == 'mdat') {
      await _copyMdatData(atom, outputFile, dataOffset);
    } else if (atom.data != null && atom.type != 'meta') {
      outputFile.writeFromSync(atom.data!);
    } else {
      for (var child in atom.children) {
        dataOffset = await _writeAtomRecursive(child, outputFile, dataOffset);
      }
    }

    return offset + atom.size;
  }

  Future<void> _copyMdatData(
    Atom mdatAtom,
    RandomAccessFile outputFile,
    int dataOffset,
  ) async {
    _openRead();
    _file.setPositionSync(mdatAtom.offset + 8);
    outputFile.setPositionSync(dataOffset);

    final bufferSize = 1024 * 1024; // 1 MB buffer
    var remaining = mdatAtom.size - 8;

    while (remaining > 0) {
      final chunkSize = remaining > bufferSize ? bufferSize : remaining;
      final chunk = _file.readSync(chunkSize);
      outputFile.writeFromSync(chunk);
      remaining -= chunkSize;
    }
    close();
  }

  Uint8List _intToBytes(int value, int byteCount) {
    final bytes = ByteData(byteCount)..setUint32(0, value, Endian.big);
    return bytes.buffer.asUint8List();
  }

  Atom? encodeMetadataAtom(String key, dynamic value) {
    final atomName = _friendlyToAtomNames[key] ?? key;

    final newAtom = Atom(atomName, 0, 0);
    final dataAtom = Atom('data', 0, 8);

    final encodedValue = _encodeMetadataValue(value);
    dataAtom.data = Uint8List.fromList(
      [0, 0, 0, 1, 0, 0, 0, 0, ...encodedValue],
    );
    dataAtom.size = dataAtom.data!.length + 8;

    newAtom.children.add(dataAtom);
    newAtom.size = dataAtom.size + 8;

    return newAtom;
  }

  Atom? reencodeMetadataAtom(String key) {
    final atomName = _friendlyToAtomNames[key] ?? key;
    final value = _metadata.get(key);
    if (value == null) return null;

    final newAtom = Atom(atomName, 0, 0);
    final dataAtom = Atom('data', 0, 8);

    final encodedValue = _encodeMetadataValue(value);
    dataAtom.data = Uint8List.fromList(
      [0, 0, 0, 1, 0, 0, 0, 0, ...encodedValue],
    );
    dataAtom.size = dataAtom.data!.length + 8;

    newAtom.children.add(dataAtom);
    newAtom.size = dataAtom.size + 8;

    return newAtom;
  }

  Uint8List _encodeMetadataValue(dynamic value) {
    if (value is String) {
      return Uint8List.fromList(utf8.encode(value));
    } else if (value is int) {
      return _intToBytes(value, 4);
    } else if (value is bool) {
      return Uint8List.fromList([value ? 1 : 0]);
    } else if (value is List<int> && value.length == 2) {
      // For numeric pairs like track number or disk number
      return Uint8List.fromList(
          [0, 0, ...value.expand((i) => _intToBytes(i, 2))]);
    } else {
      throw MP4Exception(
        'Unsupported metadata value type: ${value.runtimeType}',
      );
    }
  }

  Future<void> applyMetadataChanges() async {
    if (_pendingOperations.isEmpty) {
      _logger.i('No pending metadata operations to apply.');
      return;
    }

    Atom? ilstAtom = findAtomByPath(['moov', 'udta', 'meta', 'ilst']);
    if (ilstAtom == null) {
      throw MP4Exception('ilst atom not found');
    }

    for (var operation in _pendingOperations) {
      switch (operation.type) {
        case OperationType.add:
        case OperationType.update:
          _addOrUpdateMetadata(ilstAtom, operation.key, operation.value);
          break;
        case OperationType.remove:
          _removeMetadata(ilstAtom, operation.key);
          break;
      }
    }

    _sortIlstAtoms(ilstAtom);
    updateTreeSizes();
    updateTreeOffsets();

    try {
      await _safeWriteUpdatedAtoms();
      _pendingOperations.clear();
      _setup(); // Reopen the file and rebuild the atom tree
    } catch (e) {
      throw MP4Exception('Failed to apply metadata changes: $e');
    }
  }

  void _addOrUpdateMetadata(
    Atom ilstAtom,
    String key,
    dynamic value,
  ) {
    final atomName = _friendlyToAtomNames[key] ?? key;
    final encodedAtom = encodeMetadataAtom(key, value);

    if (encodedAtom == null) {
      throw MP4Exception('Failed to encode metadata for key: $key');
    }

    Atom? existingAtom = _findAtom(ilstAtom, atomName);
    if (existingAtom != null) {
      int index = ilstAtom.children.indexOf(existingAtom);
      ilstAtom.children[index] = encodedAtom;
    } else {
      ilstAtom.children.add(encodedAtom);
    }
  }

  void _removeMetadata(Atom ilstAtom, String key) {
    final atomName = _friendlyToAtomNames[key] ?? key;
    ilstAtom.children.removeWhere((atom) => atom.type == atomName);
  }

  Future<void> _safeWriteUpdatedAtoms() async {
    final tempDir = await Directory.systemTemp.createTemp('mp4_update_');
    final tempFile = File('${tempDir.path}/temp_mp4');
    final backupFile = File('$_filePath.bak');

    try {
      // Write to temporary file
      final tempRAF = await tempFile.open(mode: FileMode.write);
      await _writeAtomRecursive(_root, tempRAF, 0);
      await tempRAF.close();

      // Create a backup of the original file
      await File(_filePath).copy(backupFile.path);

      // Replace the original file with the temporary file
      await tempFile.copy(_filePath);

      // If everything succeeded, delete the backup and temp files
      await backupFile.delete();
      await tempFile.delete();
      await tempDir.delete();
    } catch (e) {
      _logger.e('Error during file write: $e');

      // If backup exists, restore it
      if (await backupFile.exists()) {
        await backupFile.copy(_filePath);
        await backupFile.delete();
      }

      // Clean up temp files
      if (await tempFile.exists()) await tempFile.delete();
      if (await tempDir.exists()) await tempDir.delete();

      throw MP4Exception(
        'Failed to write updated atoms: $e',
      );
    }
  }

  void addMetadata(Map<String, dynamic> newMetadata) {
    for (var entry in newMetadata.entries) {
      _pendingOperations.add(MetadataOperation(
        OperationType.add,
        entry.key,
        entry.value,
      ));
    }
  }

  void updateMetadata(Map<String, dynamic> newMetadata) {
    for (var entry in newMetadata.entries) {
      _pendingOperations.add(MetadataOperation(
        OperationType.update,
        entry.key,
        entry.value,
      ));
    }
  }

  void removeMetadata(List<String> keys) {
    for (var key in keys) {
      _pendingOperations.add(MetadataOperation(
        OperationType.remove,
        key,
      ));
    }
  }

  void clearPendingOperations() {
    _pendingOperations.clear();
  }

  void _sortIlstAtoms(Atom ilstAtom) {
    // Define the preferred order of atoms
    final preferredOrder = _friendlyToAtomNames.values.toList();

    ilstAtom.children.sort((a, b) {
      int indexA = preferredOrder.indexOf(a.type);
      int indexB = preferredOrder.indexOf(b.type);

      if (indexA == -1 && indexB == -1) {
        return a.type.compareTo(b.type); // Alphabetical order for unknown atoms
      } else if (indexA == -1) {
        return 1; // Unknown atoms go to the end
      } else if (indexB == -1) {
        return -1; // Unknown atoms go to the end
      } else {
        return indexA.compareTo(indexB);
      }
    });
  }

  void close() {
    _file.closeSync();
  }

  // Helper methods
  Atom? _findAtom(Atom parent, String type) {
    for (final child in parent.children) {
      if (child.type == type) return child;
    }
    return null;
  }

  Atom? findAtomByPath(List<String> path) {
    Atom? current = _root;
    for (String atomType in path) {
      if (current == null) return null;
      current = _findAtom(current, atomType);
    }
    return current;
  }
}
