import 'dart:typed_data';
import 'package:collection/collection.dart';

/// Represents an atom (box) in an MP4 file.
class Atom {
  String type;
  int size;
  int offset;
  Uint8List? data;
  List<Atom> children = [];

  /// Constructs an instance of [Atom].
  Atom(
    this.type,
    this.size,
    this.offset, {
    this.data,
  });

  /// Adds a child atom to the current atom.
  void addChild(Atom child) {
    children.add(child);
  }

  /// Updates the size of the current atom and its children.
  void updateSize() {
    if (children.isNotEmpty) {
      size = children.fold(0, (sum, child) => sum + child.size);
      if (type != 'root') size += 8; // Add 8 for non-root nodes
      if (type == 'meta') size += 4; // Add 4 for meta nodes
    } else if (type == 'mdat' && data == null) {
      // For mdat, keep the existing size if data is null
    } else if (data != null) {
      size = 8 + data!.length; // Header size + data size
    } else {
      size = 8; // Just the header size for empty atoms
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
      int childOffset = offset + 8; // Start after this atom's header
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
