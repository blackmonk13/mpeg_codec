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
