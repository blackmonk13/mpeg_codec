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

  void addChild(Atom child) {
    children.add(child);
  }

  void updateSize() {
    if (children.isNotEmpty) {
      size = children.map((c) => c.size).reduce((a, b) => a + b);
      if (type != 'root') size += 8; // Add 8 for non-root nodes
      if (type == 'meta') size += 4; // Add 4 for meta nodes
    }
  }

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

  Map<String, dynamic> asMap() {
    final Map<String, dynamic> atom = {};
    children.map((e) => e.asMap());
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
}