import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'atoms.dart';
import 'exceptions.dart';
import 'handler.dart';

/// A class responsible for handling MP4 file operations.
/// This class extends the CodecHandler class and provides methods for parsing,
/// processing, and manipulating MP4 atoms and metadata.
class MP4Handler extends CodecHandler {
  /// The root atom of the MP4 file.
  late Atom _root;

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

  MP4Handler(super.filePath) {
    _setup();
  }

  /// Initializes the MP4Handler by performing the following steps:
  ///   1. Opens the file for reading.
  ///   2. Builds the atom tree of the MP4 file.
  ///   3. Prints the atom tree.
  ///   4. Parses the metadata.
  ///   5. Closes the file.
  void _setup() {
    // Open the file for reading.
    openRead();

    // Build the atom tree of the MP4 file.
    _root = _buildAtomTree();

    // Print the atom tree.
    printAtomTree(_root);

    // Parse the metadata.
    parseMetadata();

    // Close the file.
    close();
  }

  /// Builds an atom tree from the given file.
  ///
  /// This function reads the file from the beginning to the end, parsing the atoms
  /// and their children recursively. It creates an [Atom] object for each atom and
  /// adds it to the tree. The root atom is returned as the result.
  ///
  /// Parameters:
  /// - None.
  ///
  /// Returns:
  /// - An [Atom] object representing the root of the atom tree.
  Atom _buildAtomTree() {
    final root = Atom('root', file.lengthSync(), 0);
    _parseAtomRecursive(root, 0, file.lengthSync());
    return root;
  }

  List<String> printAtomTree(Atom atom, [String indent = '']) {
    List<String> output = [];
    output.add('$indent${atom.toString()}');
    for (var child in atom.children) {
      output.addAll(printAtomTree(child, '$indent  '));
    }

    if (indent.isEmpty) {
      logger.i(output.join("\n"));
    }

    return output;
  }

  /// Parses the MP4 atoms from the given [start] offset to the [end] offset.
  ///
  /// This function recursively reads the atoms from the file and constructs a tree-like structure
  /// using the [Atom] class. It handles atoms of different types, including container atoms,
  /// and special handling for the 'ilst' children.
  ///
  /// Parameters:
  /// - parent: The parent atom to which the parsed atoms should be added.
  /// - start: The starting offset in the file to parse from.
  /// - end: The ending offset in the file to parse until.
  ///
  /// The function reads the size and type of each atom from the file, and constructs an [Atom]
  /// object for each atom. It adds the atoms to the parent atom's children list. If the atom is a
  /// container atom, it recursively calls itself to parse the child atoms. If the atom is of type
  /// 'ilst', it calls the `_parseIlstChild` function to handle the special case.
  ///
  /// The function also handles atoms of type 'meta' by skipping the extra 4 bytes and storing
  /// them in the atom's data field.
  ///
  /// The function logs the parsed atoms using the `log` function.
  void _parseAtomRecursive(Atom parent, int start, int end) {
    int offset = start;
    while (offset < end) {
      file.setPositionSync(offset);
      int size = _readInt32();
      final type = _readFourCC();

      if (size == 0) {
        // Atom extends to end of file
        size = end - offset;
      } else if (size == 1) {
        // 64-bit size
        file.setPositionSync(offset + 8);
        size = _readInt64();
      }

      if (size < 8 || offset + size > end) {
        logger.w(
          'Invalid atom size or overflow: $type, size: $size, offset: $offset',
        );
        break;
      }

      final atom = Atom(type, size, offset);
      parent.children.add(atom);

      logger.d('Parsed atom: $type, size: $size, offset: $offset');

      if (parent.type == 'ilst') {
        // Special handling for 'ilst' children
        _parseIlstChild(atom, offset + 8, offset + size);
      } else if (_containerAtoms.contains(type)) {
        int childStart = offset + 8;
        if (type == 'meta') {
          // Skip the extra 4 bytes in 'meta' atom
          childStart += 4;
          file.setPositionSync(offset + 8);
          atom.data = file.readSync(4); // Store the extra 4 bytes
        }
        _parseAtomRecursive(atom, childStart, offset + size);
      } else if (type != 'mdat') {
        // Read the data for atoms other than 'mdat'
        file.setPositionSync(offset + 8);
        atom.data = file.readSync(size - 8);
      }

      offset += size;
    }
  }

  /// Parses a child atom within the 'ilst' atom.
  ///
  /// This function reads the size, type, and data of each child atom within the 'ilst' atom.
  /// It then adds the parsed child atom to the parent atom's children list.
  ///
  /// Parameters:
  /// - parent: The parent atom to which the parsed child atoms will be added.
  /// - start: The starting offset in the file where parsing should begin.
  /// - end: The ending offset in the file where parsing should stop.
  ///
  /// The function reads the file starting at the given 'start' offset and continues until
  /// the 'end' offset is reached. It reads the size and type of each child atom, and then
  /// reads the data for all child atoms. The parsed child atoms are added to the parent atom's
  /// children list.
  void _parseIlstChild(Atom parent, int start, int end) {
    int offset = start;
    while (offset < end) {
      file.setPositionSync(offset);
      int size = _readInt32();
      final type = _readFourCC();

      if (size < 8) {
        logger.d(
          'Invalid ilst child size or overflow: $type, size: $size, offset: $offset',
        );
        break;
      }

      final atom = Atom(type, size, offset);
      parent.children.add(atom);

      logger.d('Parsed ilst child: $type, size: $size, offset: $offset');

      // Read the data for all ilst children
      file.setPositionSync(offset + 8);
      atom.data = file.readSync(size - 8);

      offset += size;
    }
  }

  /// Reads a 32-bit integer from the current position in the file.
  ///
  /// This function reads 4 bytes from the file starting at the current position,
  /// interprets them as a big-endian 32-bit integer, and returns the result.
  ///
  /// @return The 32-bit integer read from the file.
  int _readInt32() {
    final buffer = file.readSync(4);
    return buffer.buffer.asByteData().getUint32(0, Endian.big);
  }

  /// Reads an 8-byte integer from the current position in the file.
  ///
  /// This function reads 8 bytes from the file starting at the current position,
  /// interprets them as an unsigned 64-bit integer in big-endian order, and returns
  /// the result.
  ///
  /// @return An unsigned 64-bit integer representing the 8 bytes read from the file.
  int _readInt64() {
    final buffer = file.readSync(8);
    return buffer.buffer.asByteData().getUint64(0, Endian.big);
  }

  /// Reads a 4-character code (FourCC) from the current position in the file.
  ///
  /// The FourCC is a 4-byte code used to identify different types of data or chunks within a file.
  ///
  /// Returns:
  /// - A [String] representing the FourCC read from the file.
  String _readFourCC() {
    final buffer = file.readSync(4);
    return String.fromCharCodes(buffer);
  }

  @override
  void parseMetadata() {
    final ftypAtom = _findAtom(_root, 'ftyp');
    _parseFtypAtom(ftypAtom);

    final moovAtom = _findAtom(_root, 'moov');
    if (moovAtom == null) {
      logger.d('moov atom not found');
      return;
    }

    final mvhdAtom = _findAtom(moovAtom, 'mvhd');
    _parseMvhdAtom(mvhdAtom);

    final udtaAtom = _findAtom(moovAtom, 'udta');
    if (udtaAtom == null) {
      logger.d('udta atom not found');
      return;
    }

    final metaAtom = _findAtom(udtaAtom, 'meta');
    if (metaAtom == null) {
      logger.d('meta atom not found');
      return;
    }

    final ilstAtom = _findAtom(metaAtom, 'ilst');
    if (ilstAtom == null) {
      logger.d('ilst atom not found');
      return;
    }

    for (final atom in ilstAtom.children) {
      _parseMetadataItem(atom);
    }
  }

  /// Parses and processes a metadata item from an MP4 atom.
  ///
  /// This function handles different types of metadata items, such as text, numeric, and special cases.
  /// It extracts the data from the given [atom], decodes it, and sets the corresponding metadata using the [setMetadata] function.
  ///
  /// Parameters:
  /// - [atom]: The MP4 atom containing the metadata item to be parsed.
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
      logger.d('Invalid data atom for ${atom.type}');
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
        setMetadata(friendlyName, _decodeText(value, dataType));
        break;

      // Numeric metadata
      case 'trkn':
      case 'disk':
        setMetadata(friendlyName, _decodeNumericPair(value));
        break;
      case 'tmpo':
      case '©mvc':
      case '©mvi':
      case 'rtng':
        setMetadata(friendlyName, _decodeInt(value));
        break;
      case 'cpil':
      case 'pgap':
        setMetadata(friendlyName, _decodeBool(value));
        break;

      // Special cases
      case 'gnre':
        setMetadata(friendlyName, _decodeGenre(value));
        break;
      case 'covr':
        setMetadata(friendlyName, value);
        break;

      default:
        logger.d('Unhandled metadata type: ${atom.type}');
    }
  }

  /// Parses and processes the 'mvhd' atom from an MP4 file.
  ///
  /// The function extracts the version and data from the given [atom].
  /// Depending on the version, it decodes the creation time, modification time,
  /// timescale, and duration from the data and sets the corresponding metadata.
  ///
  /// Parameters:
  /// - atom: The MP4 atom containing the 'mvhd' atom data to be parsed.
  void _parseMvhdAtom(Atom? atom) {
    if (atom?.data == null) {
      logger.d('mvhd atom data not found');
      return;
    }

    final atomData = atom!.data!;
    final version = atomData[0];

    final actualData = atomData.sublist(4);
    // print(String.fromCharCodes(actualData));
    if (version == 1) {
      setMetadata('creationTime', _decodeInt(actualData.sublist(4, 12)));
      setMetadata('modificationTime', _decodeInt(actualData.sublist(12, 20)));
      setMetadata('timescale', _decodeInt(actualData.sublist(20, 24)));
      setMetadata('duration', _decodeInt(actualData.sublist(24)));
    } else {
      setMetadata('creationTime', _decodeInt(actualData.sublist(4, 8)));
      setMetadata('modificationTime', _decodeInt(actualData.sublist(8, 12)));
      setMetadata('timescale', _decodeInt(actualData.sublist(12, 16)));
      setMetadata('duration', _decodeInt(actualData.sublist(16)));
    }
  }

  /// Parses and processes the 'ftyp' atom from an MP4 file.
  ///
  /// If the [atom] data is null, logs a message and returns.
  /// Otherwise, extracts the file type and version from the atom data.
  /// Decodes the file type and version, and sets the corresponding metadata.
  /// Then, extracts and decodes the compatible brands from the atom data,
  /// and sets the compatible brands metadata.
  void _parseFtypAtom(Atom? atom) {
    if (atom?.data == null) {
      logger.d('ftyp atom data not found');
      return;
    }

    final atomData = atom!.data!;

    // Extract and decode the file type
    setMetadata('fileType', _decodeText(atomData.sublist(0, 4), 1));

    // Extract and decode the file type version
    setMetadata('fileTypeVersion',
        _decodeInteger(atomData.sublist(4, 8), signed: false));

    final compatibleBrands = <String>[];
    int offset = 8;

    // Extract and decode the compatible brands
    while (offset < atomData.length) {
      compatibleBrands
          .add(_decodeText(atomData.sublist(offset, offset + 4), 1));
      offset += 4;
    }

    setMetadata('compatibleBrands', compatibleBrands);
  }

  /// Parses and processes the extended metadata from an MP4 file.
  ///
  /// The function checks if the [atom] has exactly 3 children. If not, it returns early.
  /// It then extracts the 'mean', 'name', and 'data' atoms from the children.
  /// If any of these atoms are not of the expected type, it returns early.
  ///
  /// The function decodes the 'mean' and 'name' atoms to strings, constructs a key
  /// by concatenating the mean and name strings with a dot in between.
  /// It then extracts the data type and value from the 'data' atom.
  /// Finally, it sets the metadata using the constructed key and decoded value.
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

    setMetadata(key, _decodeByType(value, dataType));
  }

  /// Decodes a byte list into a string based on the specified data type.
  ///
  /// Parameters:
  /// - value: The byte list to decode.
  /// - dataType: The type of data to decode.
  ///
  /// Returns:
  /// - A string representing the decoded value.
  ///
  /// If the data type is 1 or 3, the byte list is decoded as UTF-8.
  /// If the data type is 0 or 2, the byte list is decoded as UTF-16.
  /// If the data type is neither of the above, the byte list is decoded as UTF-8.
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

  /// Decodes a byte list into a pair of unsigned 16-bit integers.
  ///
  /// This function extracts the 2nd and 4th bytes from the given [value] and interprets them as unsigned 16-bit integers.
  /// If the [value] length is less than 8, it returns a pair of 0s.
  ///
  /// Parameters:
  /// - value: The byte list to decode.
  ///
  /// Returns:
  /// - A list of two integers representing the decoded values.
  List<int> _decodeNumericPair(Uint8List value) {
    if (value.length >= 8) {
      final data = value.buffer.asByteData();
      return [data.getUint16(2), data.getUint16(4)];
    }
    return [0, 0];
  }

  /// Decodes a byte list into a boolean value.
  ///
  /// This function interprets the first byte of the given [value] as a boolean.
  /// If the first byte is 1, the function returns true. Otherwise, it returns false.
  ///
  /// Parameters:
  /// - value: The byte list to decode. It should have at least one byte.
  ///
  /// Returns:
  /// - A boolean value representing the decoded value.
  bool _decodeBool(Uint8List value) {
    return value.isNotEmpty && value[0] == 1;
  }

  /// Decodes a byte list into a genre string based on the genre ID.
  ///
  /// If the length of the [value] is 2, it extracts the genre ID from the 2nd byte.
  /// Then, it uses the [_getGenreById] method to get the corresponding genre string.
  /// If the length of the [value] is not 2, it assumes the value is a string and decodes it using UTF-8.
  ///
  /// Parameters:
  /// - value: The byte list to decode. It should contain the genre ID as the 2nd byte.
  ///
  /// Returns:
  /// - A string representing the genre. If the length of the [value] is not 2, it returns the decoded string.
  String _decodeGenre(Uint8List value) {
    if (value.length == 2) {
      final genreId = value[1];
      return getGenreById(genreId);
    } else {
      // If it's not a numeric genre, it's likely a string
      return utf8.decode(value);
    }
  }

  /// Decodes a byte list into a value based on the given data type.
  ///
  /// Parameters:
  /// - value: The byte list to decode.
  /// - dataType: The data type to decode the value as.
  ///
  /// Returns:
  /// - The decoded value based on the given data type.
  ///
  /// Throws:
  /// - Throws an exception if the given data type is not supported.
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
        throw MP4Exception('Unsupported data type: $dataType');
    }
  }

  /// Decodes a byte list into an integer.
  ///
  /// This function interprets the first 4 bytes of the given [value] as a big-endian
  /// unsigned integer and returns the decoded value. If the length of the [value] is less than 4,
  /// the function returns 0.
  ///
  /// Parameters:
  /// - value: The byte list to decode. It should contain at least 4 bytes.
  ///
  /// Returns:
  /// - An integer representing the decoded value. If the length of the [value] is less than 4,
  ///   the function returns 0.
  int _decodeInt(Uint8List value) {
    if (value.length >= 4) {
      return value.buffer.asByteData().getUint32(0, Endian.big);
    }
    return 0;
  }

  /// Decodes a byte list into an integer based on the given data type and signedness.
  ///
  /// This function interprets the first 4 bytes of the given [value] as a big-endian
  /// unsigned integer and returns the decoded value. If the length of the [value] is less than 4,
  /// the function returns 0.
  ///
  /// Parameters:
  /// - value: The byte list to decode. It should contain at least 4 bytes.
  /// - signed: A boolean indicating whether the integer should be treated as signed.
  ///
  /// Returns:
  /// - An integer representing the decoded value based on the given data type and signedness.
  ///   If the length of the [value] is less than 4, the function returns 0.
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

  /// Adds a new node to the MP4 atom tree at the specified path.
  ///
  /// The function first checks if the provided path starts with the root node type.
  /// If not, it logs an error message and returns false.
  ///
  /// Then, it traverses the atom tree based on the given path, creating new parent nodes
  /// if necessary. If the path leads to an existing node, the function adds the new node as a child.
  ///
  /// After adding the new node, the function updates the sizes and offsets of the affected atoms
  /// in the tree.
  ///
  /// Parameters:
  /// - path: A list of strings representing the path to the new node in the atom tree.
  /// - newNode: The new node to be added to the atom tree.
  ///
  /// Returns:
  /// - A boolean indicating whether the new node was successfully added to the atom tree.
  ///   Returns true if the node was added, and false otherwise.
  bool addNode(List<String> path, Atom newNode) {
    if (path.isEmpty || path[0] != _root.type) {
      logger.d('Path must start with the root node type');
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

  /// Replaces an existing node in the MP4 atom tree with a new node at the specified path.
  ///
  /// Parameters:
  /// - path: A list of strings representing the path to the node to be replaced in the atom tree.
  ///   The path should start with the root node type.
  /// - newNode: The new node to replace the existing node in the atom tree.
  ///
  /// Returns:
  /// - A boolean indicating whether the replacement was successful. Returns true if the node was replaced,
  ///   and false otherwise.
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
        logger.d('Node not found: ${path[i]}');
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

  /// Updates the sizes of all atoms in the MP4 atom tree starting from the root.
  ///
  /// This function traverses the atom tree recursively, updating the size of each atom
  /// by summing the sizes of its children and adding the size of the atom's data.
  void updateTreeSizes() {
    _updateNodeSize(_root);
  }

  /// Updates the size of the given [node] and all its children recursively.
  ///
  /// This function iterates through the children of the given [node], recursively
  /// calls itself for each child, and then updates the size of the [node] by summing
  /// the sizes of its children and adding the size of the [node]'s data.
  ///
  /// Parameters:
  /// - [node]: The node for which to update the size and its children's sizes.
  void _updateNodeSize(Atom node) {
    for (int i = 0; i < node.children.length; i++) {
      _updateNodeSize(node.children[i]);
    }
    node.updateSize();
  }

  /// Updates the offsets of all atoms in the MP4 atom tree starting from the root.
  ///
  /// This function traverses the atom tree recursively, updating the offset of each atom
  /// by summing the offsets of its parent and previous siblings. The offset of the root atom
  /// is set to 0.
  void updateTreeOffsets() {
    _root.updateOffsets(0);
  }

  @override
  Future<void> writeToFile(String outputPath) async {
    final outputFile = File(outputPath).openSync(mode: FileMode.write);

    try {
      await _writeAtomRecursive(_root, outputFile, 0);
    } finally {
      outputFile.closeSync();
    }

    logger.d('File written successfully to: $outputPath');
  }

  /// Recursively writes the given [atom] and its children to the given [outputFile]
  /// starting at the given [offset].
  ///
  /// Parameters:
  /// - [atom]: The atom to write, or the root atom if writing the entire tree.
  /// - [outputFile]: The file to which the atom(s) should be written.
  /// - [offset]: The offset in [outputFile] at which to start writing.
  ///
  /// This function writes the size and type of the given [atom] to [outputFile]
  /// starting at [offset]. If the [atom] is a 'meta' atom, it writes 4 null bytes
  /// immediately after the type. If the [atom] is an 'mdat' atom, it calls
  /// [_copyMdatData] to copy the data from the 'mdat' atom to [outputFile]
  /// starting at [dataOffset]. Otherwise, if the [atom] has data, it writes the
  /// data to [outputFile] starting at [dataOffset]. If the [atom] has children,
  /// it recursively calls itself for each child, updating the [offset] as it
  /// goes.
  ///
  /// Returns the new offset in [outputFile] after writing all the data.
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
    outputFile.writeFromSync(intToBytes(atom.size, 4));
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

  /// Copies the data of an 'mdat' atom to the output file.
  ///
  /// Parameters:
  /// - [mdatAtom]: The 'mdat' atom containing the data to be copied.
  /// - [outputFile]: The file to which the data should be written.
  /// - [dataOffset]: The offset in [outputFile] at which to start writing.
  ///
  /// This function reads the data from the 'mdat' atom and writes it to
  /// [outputFile] starting at [dataOffset]. The data is copied in chunks of
  /// 5 MB.
  ///
  /// Returns: A [Future] that completes when the data has been successfully
  /// copied.
  Future<void> _copyMdatData(
    Atom mdatAtom,
    RandomAccessFile outputFile,
    int dataOffset,
  ) async {
    openRead();
    file.setPositionSync(mdatAtom.offset + 8);
    outputFile.setPositionSync(dataOffset);

    final bufferSize = 5 * 1024 * 1024; // 5 MB buffer
    int remaining = mdatAtom.size - 8;

    while (remaining > 0) {
      final chunkSize = remaining > bufferSize ? bufferSize : remaining;
      final chunk = file.readSync(chunkSize);
      outputFile.writeFromSync(chunk);
      remaining -= chunkSize;
    }

    close();
  }

  

  /// Encodes a metadata atom for the given key and value into an [Atom] object.
  ///
  /// The function searches for the value associated with the given key in the
  /// metadata map and encodes it into an atom. If the value is not found, it
  /// returns `null`.
  ///
  /// Parameters:
  /// - key: The key of the metadata value to encode.
  /// - value: The value of the metadata to encode.
  ///
  /// Returns:
  /// - An [Atom] object representing the encoded metadata atom, or `null` if
  ///   the value is not found.
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

  /// Encodes a metadata atom for the given key and returns it as an [Atom] object.
  ///
  /// This function searches for the value associated with the given key in the metadata map
  /// and encodes it into an atom. If the value is not found, it returns `null`.
  ///
  /// Parameters:
  /// - key: The key of the metadata value to encode.
  ///
  /// Returns:
  /// - An [Atom] object representing the encoded metadata value, or `null` if the value is not found.
  Atom? reencodeMetadataAtom(String key) {
    final atomName = _friendlyToAtomNames[key] ?? key;
    final value = getMetadata(key);
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

  /// Encodes the given metadata value into a byte list.
  ///
  /// This function supports encoding metadata values of type String, int, bool, and List<int> with a length of 2.
  ///
  /// Parameters:
  /// - value: The metadata value to encode.
  ///
  /// Returns:
  /// - A Uint8List containing the encoded metadata value.
  ///
  /// Throws:
  /// - MP4Exception if the given value is of an unsupported type.
  Uint8List _encodeMetadataValue(dynamic value) {
    if (value is String) {
      return Uint8List.fromList(utf8.encode(value));
    } else if (value is int) {
      return intToBytes(value, 4);
    } else if (value is bool) {
      return Uint8List.fromList([value ? 1 : 0]);
    } else if (value is List<int> && value.length == 2) {
      // For numeric pairs like track number or disk number
      return Uint8List.fromList(
          [0, 0, ...value.expand((i) => intToBytes(i, 2))]);
    } else {
      throw MP4Exception(
        'Unsupported metadata value type: ${value.runtimeType}',
      );
    }
  }

  @override
  Future<void> applyMetadataChanges() async {
    if (pendingOperations.isEmpty) {
      logger.i('No pending metadata operations to apply.');
      return;
    }

    Atom? ilstAtom = findAtomByPath(['moov', 'udta', 'meta', 'ilst']);
    if (ilstAtom == null) {
      throw MP4Exception('ilst atom not found');
    }

    for (var operation in pendingOperations) {
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
      pendingOperations.clear();
      _setup(); // Reopen the file and rebuild the atom tree
    } catch (e) {
      throw MP4Exception('Failed to apply metadata changes: $e');
    }
  }

  /// Adds or updates metadata in the given [ilstAtom] based on the given [key] and [value].
  ///
  /// This function first encodes the given [value] into an atom using the [encodeMetadataAtom] method.
  /// If the encoding is successful, it then searches for an existing atom in the [ilstAtom] with a type
  /// that matches the [atomName] derived from the [key]. If an existing atom is found, it updates
  /// the atom with the encoded metadata atom. If no existing atom is found, it adds the encoded
  /// metadata atom to the children of the [ilstAtom].
  ///
  /// If the encoding fails (i.e., the [encodedAtom] is null), it throws an [MP4Exception] with a
  /// message indicating the failure.
  ///
  /// Parameters:
  /// - [ilstAtom]: The atom from which to add or update metadata.
  /// - [key]: The key of the metadata to add or update. The [atomName] is derived from this key.
  /// - [value]: The value of the metadata to add or update.
  ///
  /// Throws:
  /// - [MP4Exception] if the encoding of metadata fails.
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

  /// Removes metadata from the given [ilstAtom] based on the given [key].
  ///
  /// The function looks for an atom in the [ilstAtom] children with a type that matches the
  /// [atomName] derived from the [key]. If such an atom is found, it is removed from the children.
  ///
  /// Parameters:
  /// - [ilstAtom]: The atom from which to remove metadata.
  /// - [key]: The key of the metadata to remove. The [atomName] is derived from this key.
  void _removeMetadata(Atom ilstAtom, String key) {
    final atomName = _friendlyToAtomNames[key] ?? key;
    ilstAtom.children.removeWhere((atom) => atom.type == atomName);
  }

  /// Writes the updated atoms to a temporary file, creates a backup of the original file,
  /// replaces the original file with the temporary file, and cleans up temporary files.
  ///
  /// This function is responsible for ensuring that the MP4 file is updated correctly and safely.
  /// It creates a temporary file, writes the updated atoms to it, creates a backup of the original file,
  /// replaces the original file with the temporary file, and cleans up temporary files.
  ///
  /// If an error occurs during the file write process, the function restores the backup file,
  /// deletes the temporary files, and throws an [MP4Exception].
  ///
  /// Parameters:
  /// - None.
  ///
  /// Returns:
  /// - A [Future] that completes when the file write process is finished.
  ///
  /// Throws:
  /// - An [MP4Exception] if an error occurs during the file write process.
  Future<void> _safeWriteUpdatedAtoms() async {
    final tempDir = await Directory.systemTemp.createTemp('mp4_update_');
    final tempFile = File('${tempDir.path}/temp_mp4');
    final backupFile = File('${file.path}.bak');

    try {
      // Write to temporary file
      final tempRAF = await tempFile.open(mode: FileMode.write);
      await _writeAtomRecursive(_root, tempRAF, 0);
      await tempRAF.close();

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

      throw MP4Exception(
        'Failed to write updated atoms: $e',
      );
    }
  }

  /// Sorts the children of the given [ilstAtom] based on a preferred order.
  ///
  /// The preferred order is defined by the [_friendlyToAtomNames] map, which maps friendly names
  /// of metadata keys to their corresponding atom types. The function sorts the children of the
  /// [ilstAtom] based on the index of each child's type in the preferred order list.
  ///
  /// If a child's type is not found in the preferred order list, it is placed at the end of the sorted list.
  ///
  /// Parameters:
  /// - [ilstAtom]: The atom whose children need to be sorted.
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

  /// Finds an atom in the MP4 file tree based on the given type.
  ///
  /// This function traverses the children of the given parent atom and returns the first atom
  /// that matches the given type. If no matching atom is found, it returns null.
  ///
  /// Parameters:
  /// - parent: The parent atom from which to start the search.
  /// - type: The type of the atom to find.
  ///
  /// Returns:
  /// - An [Atom] object if a matching atom is found.
  /// - Null if no matching atom is found.
  Atom? _findAtom(Atom parent, String type) {
    for (final child in parent.children) {
      if (child.type == type) return child;
    }
    return null;
  }

  /// Finds an atom in the MP4 file tree based on the given path.
  ///
  /// The path is a list of atom types, where each type represents a node in the tree.
  /// The function starts from the root node and traverses the tree according to the path.
  ///
  /// If the path is valid and the corresponding atom is found, the function returns the atom.
  /// If the path is invalid or the corresponding atom is not found, the function returns null.
  ///
  /// Parameters:
  /// - [path]: A list of strings representing the atom types in the path.
  ///
  /// Returns:
  /// - An [Atom] object if the path is valid and the corresponding atom is found.
  /// - Null if the path is invalid or the corresponding atom is not found.
  Atom? findAtomByPath(List<String> path) {
    Atom? current = _root;
    for (String atomType in path) {
      if (current == null) return null;
      current = _findAtom(current, atomType);
    }
    return current;
  }
}
