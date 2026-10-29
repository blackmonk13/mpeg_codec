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
  Atom _root = Atom('root', 0, 0);

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
    // Forget anything left over from an earlier parse.
    metadata.clear();

    // Open the file for reading.
    openRead();

    try {
      // Build the atom tree of the MP4 file.
      _root = _buildAtomTree();

      // Print the atom tree.
      printAtomTree(_root);

      // Parse the metadata.
      parseMetadata();

      if (metadata.asMap().isNotEmpty) {
        setMetadata('filePath', file.path);
      }
    } catch (e) {
      logger.w('Error parsing metadata: $e');
    } finally {
      // Close the file.
      close();
    }
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

      var headerSize = 8;
      if (size == 0) {
        // Atom extends to end of file
        size = end - offset;
      } else if (size == 1) {
        // 64-bit size
        file.setPositionSync(offset + 8);
        size = _readInt64();
        headerSize = 16;
      }

      if (size < headerSize || offset + size > end) {
        logger.w(
          'Invalid atom size or overflow: $type, size: $size, offset: $offset',
        );
        break;
      }

      final atom = Atom(type, size, offset)..headerSize = headerSize;
      parent.children.add(atom);

      logger.d('Parsed atom: $type, size: $size, offset: $offset');

      if (parent.type == 'ilst') {
        // Special handling for 'ilst' children
        _parseIlstChild(atom, offset + headerSize, offset + size);
      } else if (_containerAtoms.contains(type)) {
        int childStart = offset + headerSize;
        if (type == 'meta') {
          // Skip the extra 4 bytes in 'meta' atom
          childStart += 4;
          file.setPositionSync(offset + headerSize);
          atom.data = file.readSync(4); // Store the extra 4 bytes
        }
        _parseAtomRecursive(atom, childStart, offset + size);
      } else if (type != 'mdat') {
        // Read the data for atoms other than 'mdat'
        file.setPositionSync(offset + headerSize);
        atom.data = file.readSync(size - headerSize);
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
    int fileSize = file.lengthSync();
    setMetadata('size', fileSize); // Add file size to metadata

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
        dataAtom.type != 'data') {
      return;
    }

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
    // 'trkn' is 8 bytes, 'disk' is 6.
    if (value.length >= 6) {
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
    if (value.isNotEmpty && value.length <= 8) {
      // Big-endian, whatever the width (tempo is 2 bytes, rating 1).
      return value.fold(0, (number, byte) => (number << 8) | byte);
    }
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

  /// Writes the file, with the current atom tree, to [outputPath].
  ///
  /// `mdat` atoms are copied from the original file. If an `mdat` ends up at
  /// a different position, the chunk offsets in the `stco` and `co64` atoms
  /// are adjusted to match.
  @override
  Future<void> writeToFile(String outputPath) async {
    updateTreeSizes();
    _writeTree(outputPath);
    logger.d('File written successfully to: $outputPath');
  }

  void _writeTree(String outputPath) {
    final topLevel = _root.children;

    // Where each top-level atom ends up in the output.
    final newOffsets = Map<Atom, int>.identity();
    var position = 0;
    for (final atom in topLevel) {
      newOffsets[atom] = position;
      position += atom.size;
    }

    final moves = <({int start, int end, int newStart})>[
      for (final atom in topLevel.where((a) => a.type == 'mdat'))
        (
          start: atom.sourceOffset,
          end: atom.sourceOffset + atom.size,
          newStart: newOffsets[atom]!,
        ),
    ];
    final moved = moves.any((move) => move.start != move.newStart);

    if (moved && topLevel.any((a) => a.type == 'moof' || a.type == 'sidx')) {
      throw MP4Exception(
        'Fragmented MP4 files cannot be rewritten: their offsets would change',
      );
    }

    final input = File(file.path).openSync(mode: FileMode.read);
    final output = File(outputPath).openSync(mode: FileMode.write);
    try {
      for (final atom in topLevel) {
        _writeAtom(atom, input, output, moved ? moves : null);
        final expectedEnd = newOffsets[atom]! + atom.size;
        if (output.positionSync() != expectedEnd) {
          throw MP4Exception(
            'Wrote the wrong number of bytes for ${atom.type}: '
            'ended at ${output.positionSync()}, expected $expectedEnd',
          );
        }
      }
    } finally {
      input.closeSync();
      output.closeSync();
    }
  }

  void _writeAtom(
    Atom atom,
    RandomAccessFile input,
    RandomAccessFile output,
    List<({int start, int end, int newStart})>? moves,
  ) {
    output.writeFromSync(_atomHeader(atom));

    if (atom.type == 'mdat' && atom.data == null && atom.children.isEmpty) {
      _copyRange(
        input,
        atom.sourceOffset + atom.headerSize,
        atom.size - atom.headerSize,
        output,
      );
    } else if (atom.type == 'meta') {
      // The version and flags that come before the children of a 'meta' atom.
      final flags = atom.data;
      output.writeFromSync(
        flags != null && flags.length == 4 ? flags : Uint8List(4),
      );
      for (final child in atom.children) {
        _writeAtom(child, input, output, moves);
      }
    } else if (atom.data != null) {
      // 'trak' atoms are kept as raw data, which includes their chunk offsets.
      output.writeFromSync(
        atom.type == 'trak' && moves != null
            ? _patchChunkOffsets(atom.data!, moves)
            : atom.data!,
      );
    } else {
      for (final child in atom.children) {
        _writeAtom(child, input, output, moves);
      }
    }
  }

  Uint8List _atomHeader(Atom atom) {
    final type = latin1.encode(atom.type);
    if (type.length != 4) {
      throw MP4Exception('Invalid atom type: ${atom.type}');
    }

    if (atom.headerSize == 16) {
      final header = ByteData(16)
        ..setUint32(0, 1)
        ..setUint64(8, atom.size);
      header.buffer.asUint8List().setRange(4, 8, type);
      return header.buffer.asUint8List();
    }

    if (atom.size > 0xFFFFFFFF) {
      throw MP4Exception('Atom ${atom.type} is too large for a 32-bit size');
    }
    final header = ByteData(8)..setUint32(0, atom.size);
    header.buffer.asUint8List().setRange(4, 8, type);
    return header.buffer.asUint8List();
  }

  void _copyRange(
    RandomAccessFile input,
    int start,
    int length,
    RandomAccessFile output,
  ) {
    input.setPositionSync(start);
    final buffer = Uint8List(1024 * 1024);
    var remaining = length;
    while (remaining > 0) {
      final read = input.readIntoSync(
        buffer,
        0,
        remaining < buffer.length ? remaining : buffer.length,
      );
      if (read == 0) {
        throw MP4Exception('Unexpected end of file while copying media data');
      }
      output.writeFromSync(buffer, 0, read);
      remaining -= read;
    }
  }

  /// Returns a copy of the 'trak' payload [trak] with every chunk offset in
  /// its `stco` and `co64` atoms moved along with the `mdat` it points into.
  Uint8List _patchChunkOffsets(
    Uint8List trak,
    List<({int start, int end, int newStart})> moves,
  ) {
    final patched = Uint8List.fromList(trak);
    final view = ByteData.sublistView(patched);

    int remap(int offset) {
      for (final move in moves) {
        if (offset >= move.start && offset < move.end) {
          return offset - move.start + move.newStart;
        }
      }
      logger.w('Chunk offset $offset is not inside any mdat atom');
      return offset;
    }

    void walk(int start, int end) {
      var position = start;
      while (position + 8 <= end) {
        var size = view.getUint32(position);
        final type = latin1.decode(patched.sublist(position + 4, position + 8));
        var headerSize = 8;
        if (size == 1) {
          if (position + 16 > end) return;
          size = view.getUint64(position + 8);
          headerSize = 16;
        } else if (size == 0) {
          size = end - position;
        }
        if (size < headerSize || position + size > end) return;

        final bodyStart = position + headerSize;
        final boxEnd = position + size;
        switch (type) {
          case 'mdia':
          case 'minf':
          case 'stbl':
            walk(bodyStart, boxEnd);
            break;
          case 'stco':
          case 'co64':
            final wide = type == 'co64';
            final width = wide ? 8 : 4;
            // Version and flags, then the entry count, then the entries.
            final count = view.getUint32(bodyStart + 4);
            final entries = bodyStart + 8;
            if (entries + count * width > boxEnd) return;
            for (var i = 0; i < count; i++) {
              final at = entries + i * width;
              final old = wide ? view.getUint64(at) : view.getUint32(at);
              final moved = remap(old);
              if (wide) {
                view.setUint64(at, moved);
              } else if (moved > 0xFFFFFFFF) {
                throw MP4Exception(
                  'Chunk offset $moved does not fit in a stco atom',
                );
              } else {
                view.setUint32(at, moved);
              }
            }
            break;
        }
        position += size;
      }
    }

    walk(0, patched.length);
    return patched;
  }

  /// Atoms whose value is a number, as opposed to text.
  static const Set<String> _numericAtoms = {
    'trkn',
    'disk',
    'tmpo',
    'rtng',
    '©mvc',
    '©mvi',
    'cpil',
    'pgap',
  };

  /// Encodes the given metadata [value] into an `ilst` item atom for [key].
  ///
  /// Throws an [MP4Exception] if the atom name is not four bytes long or the
  /// value cannot be stored in that atom.
  Atom? encodeMetadataAtom(String key, dynamic value) {
    final atomName = _friendlyToAtomNames[key] ?? key;
    if (atomName.length != 4 || atomName.codeUnits.any((c) => c > 0xFF)) {
      throw MP4Exception('Not a valid atom name: $atomName (from key: $key)');
    }

    final encoded = _encodeMetadataValue(atomName, value);
    final dataAtom = Atom(
      'data',
      0,
      8,
      // Version 0 and the data type as flags, then a zero locale.
      data: Uint8List.fromList([0, 0, 0, encoded.type, 0, 0, 0, 0, ...encoded.bytes]),
    )..updateSize();

    final newAtom = Atom(atomName, 0, 0)..children.add(dataAtom);
    newAtom.updateSize();
    return newAtom;
  }

  /// Re-encodes the current value of [key].
  Atom? reencodeMetadataAtom(String key) {
    final value = getMetadata(key);
    if (value == null) return null;
    return encodeMetadataAtom(key, value);
  }

  /// Encodes [value] for the atom [atomName]: the `data` atom type and its bytes.
  ({int type, Uint8List bytes}) _encodeMetadataValue(
    String atomName,
    dynamic value,
  ) {
    switch (atomName) {
      case 'trkn':
      case 'disk':
        final pair = value is int ? [value, 0] : value;
        if (pair is! List<int> ||
            pair.length != 2 ||
            pair.any((n) => n < 0 || n > 0xFFFF)) {
          throw MP4Exception(
            '$atomName needs a number or a [number, total] pair of 16-bit '
            'values, got: $value',
          );
        }
        // Two reserved bytes, the number, the total and (for tracks) two more
        // reserved bytes.
        final bytes = ByteData(atomName == 'trkn' ? 8 : 6)
          ..setUint16(2, pair[0])
          ..setUint16(4, pair[1]);
        return (type: 0, bytes: bytes.buffer.asUint8List());

      case 'covr':
        if (value is! Uint8List) {
          throw MP4Exception('covr needs image bytes, got: ${value.runtimeType}');
        }
        return (type: _imageDataType(value), bytes: value);

      case 'tmpo':
        return _encodeInteger(atomName, value, 2);

      case 'rtng':
      case '©mvc':
      case '©mvi':
      case 'cpil':
      case 'pgap':
        return _encodeInteger(atomName, value, 1);
    }

    if (value is String) {
      return (type: 1, bytes: Uint8List.fromList(utf8.encode(value)));
    }
    if (value is int && !_numericAtoms.contains(atomName)) {
      // For example a year given as 1999 rather than '1999'.
      return (type: 1, bytes: Uint8List.fromList(utf8.encode('$value')));
    }
    throw MP4Exception(
      'Unsupported metadata value type: ${value.runtimeType} for $atomName',
    );
  }

  /// Encodes a signed big-endian integer, in at least [minWidth] bytes.
  ({int type, Uint8List bytes}) _encodeInteger(
    String atomName,
    dynamic value,
    int minWidth,
  ) {
    final number = value is bool ? (value ? 1 : 0) : value;
    if (number is! int) {
      throw MP4Exception('$atomName needs a number, got: ${value.runtimeType}');
    }

    for (final width in [1, 2, 4, 8]) {
      if (width < minWidth) continue;
      final limit = width == 8 ? null : 1 << (width * 8 - 1);
      if (limit != null && (number < -limit || number >= limit)) continue;

      final bytes = ByteData(width);
      switch (width) {
        case 1:
          bytes.setInt8(0, number);
          break;
        case 2:
          bytes.setInt16(0, number);
          break;
        case 4:
          bytes.setInt32(0, number);
          break;
        default:
          bytes.setInt64(0, number);
      }
      return (type: 21, bytes: bytes.buffer.asUint8List());
    }
    throw MP4Exception('Number does not fit in $atomName: $number');
  }

  /// The `data` atom type for image bytes: 13 JPEG, 14 PNG, 12 GIF, 27 BMP.
  int _imageDataType(Uint8List image) {
    if (image.length > 3) {
      if (image[0] == 0x89 && image[1] == 0x50) return 14;
      if (image[0] == 0x47 && image[1] == 0x49 && image[2] == 0x46) return 12;
      if (image[0] == 0x42 && image[1] == 0x4D) return 27;
    }
    return 13;
  }

  /// Applies the queued operations and rewrites the file.
  ///
  /// Setting a key replaces every item with that atom name, and removing a
  /// key removes them all. Missing `udta`, `meta` and `ilst` atoms are
  /// created. The file is only replaced once the new one has been written
  /// completely, so a failure leaves the original untouched.
  ///
  /// Throws an [MP4Exception] if a value cannot be encoded or the file cannot
  /// be written.
  @override
  Future<void> applyMetadataChanges() async {
    if (pendingOperations.isEmpty) {
      logger.i('No pending metadata operations to apply.');
      return;
    }

    final moov = _findAtom(_root, 'moov');
    if (moov == null) {
      throw MP4Exception('moov atom not found');
    }

    // Work on a copy of the items so that a bad value changes nothing.
    final existingIlst = findAtomByPath(['moov', 'udta', 'meta', 'ilst']);
    final items = List<Atom>.of(existingIlst?.children ?? []);
    for (final operation in pendingOperations) {
      switch (operation.type) {
        case OperationType.add:
        case OperationType.update:
          _addOrUpdateItem(items, operation.key, operation.value);
          break;
        case OperationType.remove:
          final atomName = _friendlyToAtomNames[operation.key] ?? operation.key;
          items.removeWhere((atom) => atom.type == atomName);
          break;
      }
    }

    final undo = <void Function()>[];
    try {
      final ilst = existingIlst ?? _createIlst(moov, undo);
      final previous = ilst.children;
      ilst.children = items;
      undo.add(() => ilst.children = previous);

      updateTreeSizes();
      _safeWrite();
    } catch (e) {
      for (final step in undo.reversed) {
        step();
      }
      updateTreeSizes();
      throw MP4Exception('Failed to apply metadata changes: $e');
    }

    pendingOperations.clear();
    _setup(); // Reopen the file and rebuild the atom tree
  }

  void _addOrUpdateItem(List<Atom> items, String key, dynamic value) {
    final encodedAtom = encodeMetadataAtom(key, value);
    if (encodedAtom == null) {
      throw MP4Exception('Failed to encode metadata for key: $key');
    }

    final index = items.indexWhere((atom) => atom.type == encodedAtom.type);
    items.removeWhere((atom) => atom.type == encodedAtom.type);
    // Keep the item where it was so the order of the other items is stable.
    items.insert(index == -1 ? items.length : index, encodedAtom);
  }

  /// Creates the missing atoms on the path moov/udta/meta/ilst and returns
  /// the `ilst` atom. Each step adds a function to [undo].
  Atom _createIlst(Atom moov, List<void Function()> undo) {
    Atom add(Atom parent, Atom child) {
      parent.children.add(child);
      undo.add(() => parent.children.removeWhere((a) => identical(a, child)));
      return child;
    }

    final udta = _findAtom(moov, 'udta') ?? add(moov, Atom('udta', 0, 0));
    var meta = _findAtom(udta, 'meta');
    if (meta == null) {
      meta = add(udta, Atom('meta', 0, 0, data: Uint8List(4)));
      add(
        meta,
        Atom(
          'hdlr',
          0,
          0,
          data: Uint8List.fromList([
            0, 0, 0, 0, // version and flags
            0, 0, 0, 0, // pre-defined
            ...latin1.encode('mdir'), // handler type: metadata
            ...latin1.encode('appl'), // manufacturer
            0, 0, 0, 0, 0, 0, 0, 0, // reserved
            0, // empty name
          ]),
        ),
      );
    }
    return add(meta, Atom('ilst', 0, 0));
  }

  /// Writes the updated file next to the original and renames it over the
  /// original, so the original is never half-written.
  void _safeWrite() {
    final path = file.path;
    final tempFile = File('$path.tmp');
    try {
      _writeTree(tempFile.path);
      tempFile.renameSync(path);
    } catch (e) {
      logger.e('Error during file write: $e');
      if (tempFile.existsSync()) tempFile.deleteSync();
      rethrow;
    }
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
