import 'dart:typed_data';

class ID3v2Tag {
  int version;
  int revision;
  int flags;
  int size;
  List<ID3v2Frame> frames;

  ID3v2Tag(
    this.version,
    this.revision,
    this.flags,
    this.size,
    this.frames,
  );
}

class ID3v2Frame {
  String id;
  int size;
  Uint8List data;

  ID3v2Frame(
    this.id,
    this.size,
    this.data,
  );
}
