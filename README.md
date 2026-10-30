
A package for handling MP4 and ID3 metadata and related operations.

## Features

The package can perform the following tasks:
- Read MP4 and ID3 metadata from files that support MP4 and ID3 codecs.
- Add, update and remove MP4 and ID3 metadata.

## Usage

Initialize the respective handlers. 

#### MP4
```dart
final handler = MP4Handler(filePath);
print(handler.metadata);
```
#### ID3
```dart
final handler = ID3Handler(filePath);
print(handler.metadata);
```
#### Encoding metadata
Queue operations, then apply them all at once. Applying rewrites the file and
re-reads it, so `handler.metadata` shows what is on disk afterwards.
```dart
handler.addMetadata({
  'title': 'New Title',
  'artist': 'Artist',
});
handler.updateMetadata({'genre': 'New Genre'});
handler.removeMetadata(['artist']);

try {
  await handler.applyMetadataChanges();
  print('Metadata changes applied successfully');
} catch (e) {
  // ID3Exception or MP4Exception
  print('Failed to apply metadata changes: $e');
}
```

How writing behaves:

- Nothing is written until `applyMetadataChanges()`, and the operations are
  only removed from the queue once the file was written.
- If the new tag fits in the space the old one took (its padding, or the
  `free` atom next to it), only the tag is overwritten in the file itself and
  the audio is not copied. That is fast for big files, but a disk failure half
  way through could leave a damaged tag. Pass `inPlace: false` to always write
  a new file (`<name>.tmp`) and rename it over the original, so that a failure
  leaves the original untouched. A tag that has to grow is always written to a
  new file, with some padding for the next edit.
- Audio is copied byte for byte. `update` sets a key: it replaces every frame
  or atom for it, and `remove` removes them all. `add` is the same, except for
  cover art (`cover`, `picture`), where it appends to the pictures that are
  already there. The other frames and atoms keep their order.
- A value that cannot be stored (an unknown key, a number out of range, the
  wrong type) throws and changes nothing.
- Missing tag structures are created: an MP3 gets an ID3v2 tag, an MP4 gets
  `udta`/`meta`/`ilst`.
- Copying a file does not block the event loop, but parsing in the constructor
  does. In a Flutter app read with `await ID3Handler.readMetadata(path)` or
  `await MP4Handler.readMetadata(path)`, which parse in another isolate and
  return the `Metadata`.

##### ID3
- The tag keeps its version (2.3 or 2.4; a new tag is 2.4). Text is UTF-8 in
  2.4, and ISO-8859-1 or UTF-16 in 2.3. `year` is stored in `TDRC` in 2.4 and in
  `TYER` in 2.3; reading a `TDRC` also gives `year` (its first four digits).
- Values: strings; numbers; `[number, total]` for `track` and `discNumber`
  (stored as `3/12`); a list of strings for several values; image bytes, or a
  map with `data`, `mimeType`, `pictureType` and `description`, or a list of
  those, for `picture` (all of them are read as `pictures`); a map with
  `language`, `description` and `text` for `comment` and `lyrics`; an integer
  from 0 to 255 for `rating` (a `POPM` frame); a URL, or a map with
  `description` and `url`, for `userDefinedUrl` (`WXXX:Description` for one
  description); a map with `language`, `timeStampFormat`, `contentType`,
  `description` and `lyrics` (a list of `timeStamp` and `text` maps) for
  `synchronizedLyrics`; a map with `startTime`, `endTime` (milliseconds),
  `startOffset`, `endOffset` and `title` (or `subFrames`, a map of text frame
  ID to text) for `chapter_<id>`; a map with `children` (a list of IDs),
  `isOrdered`, `isTopLevel` and `title` for `tableOfContents_<id>`.
- `TXXX:Description` sets the user text frame with that description and leaves
  the others alone. Other frame IDs can be given as the key with the raw frame
  body as a `Uint8List`.
- An ID3v1 tag at the end of the file is kept, and the fields you change are
  updated in it too. ID3v2 values win over ID3v1 ones when reading.
- A tag that is written to a new file gets `ID3Handler.tagPadding` (1024) bytes
  of padding. Parts of a tag that look like the start of an MPEG frame
  (`FF E0` and up, as in JPEG data) are unsynchronized when writing: the whole
  tag in 2.3, the frame in 2.4. Reading undoes it.

##### MP4
- Values: strings; `trackNumber` and `discNumber` as `[number, total]`; integers
  for `bpm`, `rating` and the like; booleans for `compilation` and `gapless`;
  image bytes (JPEG, PNG, GIF or BMP) or a list of them for `cover` (all of
  them are read as `covers`).
- Freeform atoms are read and written with the key `mean.name`, for example
  `com.apple.iTunes.MOOD`.
- A change in the size of the metadata is taken out of (or given to) the `free`
  atom after `ilst` or after `moov`, so the media stays where it is. If there is
  no room and `moov` comes before `mdat`, the media moves and the offsets are
  adjusted: the chunk offsets (`stco`/`co64`) and, in fragmented files, the
  `tfhd` base data offsets, the `sidx` first offsets and the `tfra` `moof`
  offsets. `MP4Handler.freePadding` (1024) bytes of `free` atom are left after
  `moov` then. With `moov` at the end of the file it simply grows or shrinks.
- `duration` is in milliseconds, like for ID3. `timescale` and `durationTicks`
  hold the raw values.

## Metadata

| MP4          | ID3                |
| ------------ | ------------------ |
| title        | title              |
| artist       | artist             |
| album        | album              |
| year         | year               |
| genre        | genre              |
| composer     | composer           |
| lyrics       | lyrics             |
| comment      | comment            |
| albumArtist  | albumArtist        |
| trackNumber  | track              |
| discNumber   | discNumber         |
| bpm          | bpm                |
| cover        | picture            |
| description  |                    |
| copyright    | copyright          |
| rating       | rating             |
| duration     | duration           |

`Metadata.get<T>` returns `null` when the value is not a `T`, instead of
throwing.

## License

MIT, see [LICENSE](LICENSE).
