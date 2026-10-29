## 2.1.0

Additions

- Edits are made in place when the new tag fits in the space of the old one
  (ID3 padding, MP4 `free` atoms), without copying the audio. Pass
  `applyMetadataChanges(inPlace: false)` for the temporary file and rename of
  2.0.0. Tags that have to grow get padding (`ID3Handler.tagPadding`,
  `MP4Handler.freePadding`) so the next edit fits.
- `ID3Handler.readMetadata(path)` and `MP4Handler.readMetadata(path)` read in
  another isolate.
- `addMetadata` appends cover art (`cover`, `picture`) to the pictures that are
  there; `updateMetadata` replaces them.
- Fragmented MP4 files can be edited: `tfhd`, `sidx` and `tfra` offsets are
  moved with the media, where 2.0.0 refused.
- ID3 writing of `WXXX` (`userDefinedUrl`), `SYLT` (`synchronizedLyrics`),
  `CHAP` (`chapter_<id>`) and `CTOC` (`tableOfContents_<id>`) frames.
- ID3 unsynchronization is applied when writing a tag that has false MPEG
  syncs in it (2.3 for the tag, 2.4 for the frame).

Fixes

- ID3 reading: `SYLT`, `CHAP` and `CTOC` frames could not be read (the tag
  was not set yet), `SYLT` entries were read in the wrong order, chapter
  titles replaced the title of the track, `WXXX` was not read, unsynchronized
  2.4 frames were not undone, and an unsynchronized 2.3 tag lost a byte at the
  end.
- MP4: `free` and `skip` atoms are no longer read into memory.
- Operations queued while `applyMetadataChanges` is writing stay queued.

## 2.0.0

Breaking changes

- ID3 `track` and `discNumber` are `[number, total]` lists. `trackNumber` and
  `totalTracks` are no longer set for ID3.
- MP4 `duration` is in milliseconds, like ID3 (the raw values are
  `durationTicks` and `timescale`).
- `Metadata.get<T>` returns `null` for a value of another type instead of
  throwing.
- `ID3Handler.registerCustomFrameHandler` is public.
- Setting or removing a key now affects every frame or atom for it (except
  ID3 `TXXX` and `POPM` frames, which are told apart by description and owner).
- Logging is no longer silenced by the library. Set `Logger.level` yourself.

Fixes

- ID3 writing: audio was copied from the wrong offset, an ID3v1 tag was added
  a second time, numbers and number pairs were written as binary, and the tag
  was always written as 2.4. Frame flags are kept now, and an ID3v1 tag stays
  in step with the changes.
- MP4 writing: the media was read from the wrong place and the chunk offsets
  were not adjusted when `moov` came before `mdat`, so editing such a file
  corrupted it. Values are written with the right data types, cover art can be
  written, and missing `udta`/`meta`/`ilst` atoms are created. Bytes that are
  not atoms (such as the terminator of `udta`) are kept.
- Both: the file is written to a temporary file and renamed, so a failure
  leaves the original intact, and re-reading clears stale metadata.
- ID3 reading: frames whose last string is not terminated (most comments,
  lyrics and user text) could not be read, ID3v1 values overwrote ID3v2 ones,
  MP3 duration was usually missing (and MPEG-2 files hit an out-of-range
  bitrate lookup).
- MP4 reading: `mvhd` times, timescale and duration were read from the wrong
  offsets, `disk` atoms, small integers and UTF-16 text were misread, and a
  corrupt file could throw from the constructor.

Additions

- ID3: `TXXX:Description`, `POPM` ratings, several pictures (`pictures`),
  maps for `comment`, `lyrics` and `picture`, and `year` from `TDRC`.
- MP4: freeform (`----`) atoms, several covers (`covers`) and 64-bit atoms.

## 1.0.0

- Initial version.
