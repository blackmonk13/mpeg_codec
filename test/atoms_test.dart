import 'dart:typed_data';
import 'package:mpeg_codec/src/atoms.dart';
import 'package:test/test.dart';

void printAtomTree(Atom atom, [String indent = '']) {
  print('$indent${atom.toString()}');
  for (var child in atom.children) {
    printAtomTree(child, '$indent  ');
  }
}

void main() {
  group('Atom', () {
    test('equality and hash code', () {
      final atom1 = Atom('test', 100, 0);
      final atom2 = Atom('test', 100, 0);
      final atom3 = Atom('other', 100, 0);

      expect(atom1, equals(atom2));
      expect(atom1.hashCode, equals(atom2.hashCode));
      expect(atom1, isNot(equals(atom3)));
      expect(atom1.hashCode, isNot(equals(atom3.hashCode)));
    });

    test('equality and hash code with children', () {
      final child1 = Atom('child1', 50, 0);
      final child2 = Atom('child2', 50, 0);

      final atom1 = Atom('test', 100, 0, data: Uint8List(100));
      final atom2 = Atom('test', 100, 0, data: Uint8List(100));
      final atom3 = Atom('test', 100, 0, data: Uint8List(150));

      atom1.addChild(child1);
      atom2.addChild(child2);

      expect(atom1, isNot(equals(atom2)));
      expect(atom1.hashCode, isNot(equals(atom2.hashCode)));
      expect(atom1, isNot(equals(atom3)));
      expect(atom1.hashCode, isNot(equals(atom3.hashCode)));
    });

    test('equality and hash code with different data', () {
      final atom1 = Atom('test', 100, 0, data: Uint8List(100));
      final atom2 = Atom('test', 100, 0, data: Uint8List(100)..[50] = 1);

      expect(atom1, isNot(equals(atom2)));
      expect(atom1.hashCode, isNot(equals(atom2.hashCode)));
    });

    test('equality and hash code with different sizes', () {
      final atom1 = Atom('test', 100, 0);
      final atom2 = Atom('test', 150, 0);

      expect(atom1, isNot(equals(atom2)));
      expect(atom1.hashCode, isNot(equals(atom2.hashCode)));
    });

    test('equality and hash code with different offsets', () {
      final atom1 = Atom('test', 100, 0);
      final atom2 = Atom('test', 100, 50);

      expect(atom1, isNot(equals(atom2)));
      expect(atom1.hashCode, isNot(equals(atom2.hashCode)));
    });

    test('Atom creation and size update', () {
      // Create an Atom instance
      final atom = Atom('root', 0, 0);

      // Add child atoms
      final child0 = Atom('moov', 50, 0);
      final child1 = Atom('trak', 100, 58);
      final child2 = Atom('mdia', 200, 158);
      atom.addChild(child0);
      atom.addChild(child1);
      atom.addChild(child2);

      // Update the size of the atom and its children
      atom.updateSize();

      // Verify the size of the atom and its children
      expect(atom.size, 350); // 50 (moov) + 100 (trak) + 200 (mdia)
      expect(child0.size, 50);
      expect(child1.size, 100);
      expect(child2.size, 200);
    });

    test('Atom creation and offset update', () {
      // Create an Atom instance
      final atom = Atom('moov', 0, 0);

      // Add child atoms
      final child1 = Atom('trak', 100, 8);
      final child2 = Atom('mdia', 200, 108);
      atom.addChild(child1);
      atom.addChild(child2);

      // Update the offsets of the atom and its children
      atom.updateOffsets(0);

      // Verify the offsets of the atom and its children
      expect(atom.offset, 0);
      expect(child1.offset, 8); // 8 (header)
      expect(child2.offset, 108); // 100 (trak)
    });

    test('Atom creation and equality', () {
      // Create two Atom instances with the same properties
      final atom1 = Atom('moov', 316, 0, data: Uint8List(10));
      final atom2 = Atom('moov', 316, 0, data: Uint8List(10));

      // Add child atoms
      final child1 = Atom('trak', 100, 8);
      final child2 = Atom('mdia', 200, 108);
      atom1.addChild(child1);
      atom1.addChild(child2);
      atom2.addChild(child1);
      atom2.addChild(child2);

      // Verify the equality of the two Atom instances
      expect(atom1, equals(atom2));
    });

    test('Atom creation and map representation', () {
      // Create an Atom instance
      final atom = Atom('moov', 316, 0, data: Uint8List(10));

      // Add child atoms
      final child1 = Atom('trak', 100, 8);
      final child2 = Atom('mdia', 200, 108);
      atom.addChild(child1);
      atom.addChild(child2);

      // Get the map representation of the Atom instance
      final atomMap = atom.asMap();

      // Verify the map representation
      expect(atomMap, {
        'moov': {
          'offset': 0,
          'size': 316,
          'hasData': true,
          'children': {
            0: {
              'trak': {
                'offset': 8,
                'size': 100,
                'hasData': false,
                'children': {},
              }
            },
            1: {
              'mdia': {
                'offset': 108,
                'size': 200,
                'hasData': false,
                'children': {},
              }
            },
          },
        },
      });
    });

    test('AddChild and RemoveChild', () {
      final atom = Atom('moov', 0, 0);
      final child1 = Atom('trak', 0, 0);
      final child2 = Atom('mdia', 0, 0);

      atom.addChild(child1);
      atom.addChild(child2);

      expect(atom.children.length, 2);
      expect(atom.children[0].type, 'trak');
      expect(atom.children[1].type, 'mdia');

      atom.children.remove(child1);

      expect(atom.children.length, 1);
      expect(atom.children[0].type, 'mdia');
    });

    test('UpdateOffsets', () {
      final root = Atom('root', 0, 0);

      final atom = Atom('moov', 0, 0);

      root.addChild(atom);
      final child1 = Atom('trak', 0, 0);
      final child2 = Atom('mdia', 0, 0);

      atom.addChild(child1);
      atom.addChild(child2);

      root.updateOffsets(0);

      expect(atom.offset, 0);
      expect(child1.offset, 8);
      expect(child2.offset, 8);
    });

    test('UpdateOffsets with meta node', () {
      final root = Atom('root', 0, 0);
      final atom = Atom('meta', 0, 0);
      final child1 = Atom('ilst', 32, 0);
      final child2 = Atom('free', 0, 0);

      root.addChild(atom);
      atom.addChild(child1);
      atom.addChild(child2);

      root.updateOffsets(0);
      printAtomTree(root);

      expect(atom.offset, 0); // 8 bytes for non-root node
      expect(child1.offset, 12); // 12 bytes for meta node
      expect(child2.offset, 44); // 0 bytes for sibling node
    });

    test('UpdateSize', () {
      final atom = Atom('moov', 0, 0);
      final child1 = Atom('trak', 100, 0);
      final child2 = Atom('mdia', 200, 0);

      atom.addChild(child1);
      atom.addChild(child2);

      atom.updateSize();

      expect(atom.size, 308); // 100 + 200 + 8 (non-root) + 8 (non-root)
    });

    test('UpdateSize with meta node', () {
      final atom = Atom('meta', 0, 0);
      final child1 = Atom('ilst', 100, 0);
      final child2 = Atom('free', 200, 0);

      atom.addChild(child1);
      atom.addChild(child2);

      atom.updateSize();

      expect(atom.size, 312); // 100 + 200 + 4 (meta) + 8 (non-root)
    });

    test('updateOffsets correctly updates offsets', () {
      // Create a root atom
      Atom root = Atom('root', 0, 0);

      // Create child atoms
      Atom child1 = Atom('child1', 100, 0);
      Atom child2 = Atom('child2', 200, 0);
      Atom child3 = Atom('child3', 300, 0);

      // Add child atoms to the root atom
      root.addChild(child1);
      root.addChild(child2);
      root.addChild(child3);

      // Update offsets for the root atom
      root.updateOffsets(0);

      // Verify the offsets of the child atoms
      expect(child1.offset, equals(0)); // 0 bytes for first non-root node
      expect(child2.offset, equals(100)); // 0 bytes for sibling non-root node
      expect(child3.offset, equals(300)); // 0 bytes for sibling non-root node

      // Create a meta atom
      Atom meta = Atom('meta', 0, 0);

      // Add the meta atom to the root atom
      root.addChild(meta);

      // Create child atoms for the meta atom
      Atom metaChild1 = Atom('metaChild1', 50, 0);
      Atom metaChild2 = Atom('metaChild2', 150, 0);

      // Add child atoms to the meta atom
      meta.addChild(metaChild1);
      meta.addChild(metaChild2);

      // Update offsets for the meta atom
      root.updateOffsets(0);
      printAtomTree(root);

      // Verify the offsets of the child atoms of the meta atom
      expect(metaChild1.offset,
          equals(612)); // 12 bytes for meta node and first child
      expect(metaChild2.offset, equals(662)); // 0 bytes for non-root node
    });
  });
}
