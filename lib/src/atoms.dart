import 'dart:typed_data';
import 'package:collection/collection.dart';

/// Represents an atom in a binary data structure.
///
/// An atom is a self-contained unit of data within a file format,
/// typically containing a type, size, offset, optional data, and a list of child atoms.
class Atom {
  /// The type of the atom.
  String type;

  /// The size of the atom in bytes.
  int size;

  /// The offset of the atom in the file.
  int offset;

  /// Where the atom started in the file it was parsed from. Unlike [offset]
  /// this is never updated, so it can be used to copy the atom's data.
  final int sourceOffset;

  /// The size the atom had in the file it was parsed from.
  final int sourceSize;

  /// Whether the atom's payload (media data or padding) is not kept in memory
  /// but copied from the original file, or written as zeros for padding, when
  /// the file is written.
  bool streamed = false;

  /// The size of the atom's header: 8 bytes, or 16 when it has a 64-bit size.
  int headerSize = 8;

  /// Bytes at the end of a container that are not atoms (for example the
  /// zero terminator of a 'udta' atom). They are written back unchanged.
  Uint8List? trailingData;

  /// The optional data associated with the atom.
  Uint8List? data;

  /// The list of child atoms contained within this atom.
  List<Atom> children = [];

  /// Constructs an instance of [Atom].
  Atom(
    this.type,
    this.size,
    this.offset, {
    this.data,
  })  : sourceOffset = offset,
        sourceSize = size;

  /// Adds a child atom to the current atom.
  void addChild(Atom child) {
    children.add(child);
  }

  /// Updates the size of the current atom and its children.
  void updateSize() {
    final trailing = trailingData?.length ?? 0;
    if (children.isNotEmpty) {
      size = children.fold(0, (sum, child) => sum + child.size);
      if (type != 'root') size += headerSize; // Add the header for non-root nodes
      if (type == 'meta') size += 4; // Add 4 for meta nodes
      size += trailing;
    } else if ((type == 'mdat' || streamed) && data == null) {
      // The payload is not in memory, so keep the size it has
    } else if (data != null) {
      size = headerSize + data!.length + trailing; // Header size + data size
    } else {
      // Just the header size (and the flags of a 'meta' atom) for empty atoms
      size = headerSize + (type == 'meta' ? 4 : 0) + trailing;
    }
  }

  /// Updates the offset of the current atom and its children.
  void updateOffsets(int parentOffset) {
    if (type == 'root') {
      offset = 0; // The root is just a container, not an actual atom
      int childOffset = 0;
      for (var child in children) {
        child.updateOffsets(childOffset);
        childOffset += child.size;
      }
    } else {
      offset = parentOffset;
      int childOffset = offset + headerSize; // Start after this atom's header
      if (type == 'meta') childOffset += 4; // Additional 4 bytes for meta

      for (var child in children) {
        child.updateOffsets(childOffset);
        childOffset += child.size;
      }
    }
  }

  /// Returns a map representation of the current atom and its children.
  Map<String, dynamic> asMap() {
    final Map<String, dynamic> atom = {};
    atom[type] = {
      'offset': offset,
      'size': size,
      'hasData': data != null,
      'children': {for (var e in children) children.indexOf(e): e.asMap()},
    };
    return Map.unmodifiable(atom);
  }

  @override
  String toString() {
    return '$type (size: $size, offset: $offset, data: ${data != null})';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Atom &&
        other.type == type &&
        other.size == size &&
        other.offset == offset &&
        const ListEquality<int>().equals(other.data, data) &&
        const DeepCollectionEquality().equals(other.children, children);
  }

  @override
  int get hashCode {
    return Object.hash(
      type,
      size,
      offset,
      data != null ? Object.hashAll(data!) : null,
      Object.hashAll(children),
    );
  }
}
