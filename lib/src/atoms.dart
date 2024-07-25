import 'dart:typed_data';

class Atom {
  String type;
  int size;
  int offset;
  Uint8List? data;
  List<Atom> children = [];

  Atom(
    this.type,
    this.size,
    this.offset, {
    this.data,
  });

  /// Adds a child atom to this atom
  void addChild(Atom child) {
    children.add(child);
  }

  /// Updates the size of this atom and all its children
  void updateSize() {
    if (children.isNotEmpty) {
      size = children.map((c) => c.size).reduce((a, b) => a + b);
      if (type != 'root') size += 8; // Add 8 for non-root nodes
      if (type == 'meta') size += 4; // Add 4 for meta nodes
    }
  }

  /// Updates the offsets of this atom and all its children
  void updateOffsets(int parentOffset, bool isFirstChild) {
    offset = parentOffset;
    if (type != 'root' && !isFirstChild) {
      // Add 8 for non-root nodes, except for the first child of root
      offset += 8;
    }

    int childOffset = offset;
    for (int i = 0; i < children.length; i++) {
      int additionalOffset = 0;
      if (type == 'meta' && i == 0) {
        // Additional 4 for the first child of meta (12 total)
        additionalOffset = 4;
      }
      children[i].updateOffsets(
        childOffset + additionalOffset,
        type == 'root',
      );
      childOffset += children[i].size;
    }
  }

  /// Returns a map representation of this atom
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
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Atom &&
          runtimeType == other.runtimeType &&
          type == other.type &&
          size == other.size &&
          offset == other.offset;

  @override
  int get hashCode => type.hashCode ^ size.hashCode ^ offset.hashCode;
}
