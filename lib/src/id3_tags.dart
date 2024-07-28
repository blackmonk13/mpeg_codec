import 'dart:typed_data';

/// Represents an ID3v2 tag in an audio file.
///
/// The ID3v2 tag is a metadata container that provides information about the audio file,
/// such as artist, album, title, and other details.
class ID3v2Tag {
  /// The version of the ID3v2 tag.
  final int version;

  /// The revision number of the ID3v2 tag.
  final int revision;

  /// The flags indicating the presence and behavior of the tag.
  final int flags;

  /// The total size of the ID3v2 tag in bytes.
  int size;

  /// A list of frames containing the actual metadata.
  final List<ID3v2Frame> frames;

  /// Constructs a new [ID3v2Tag] object.
  ID3v2Tag(
    this.version,
    this.revision,
    this.flags,
    this.size,
    this.frames,
  );
}

/// Represents a single frame in an ID3v2 tag.
///
/// Each frame contains a unique identifier (ID), a size indicating the length of the data,
/// and the actual data stored in a [Uint8List].
class ID3v2Frame {
  /// A unique identifier for the frame.
  final String id;

  /// The size of the frame's data in bytes.
  final int size;

  /// The actual data stored in the frame.
  final Uint8List data;

  /// Constructs a new [ID3v2Frame] object.
  ID3v2Frame(
    this.id,
    this.size,
    this.data,
  );
}
