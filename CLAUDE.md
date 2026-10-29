# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

`mpeg_codec`: a pure-Dart package for reading and writing MP4 (`.m4a`/`.m4p`) and ID3 (`.mp3`) metadata, modelled on Python's mutagen. It is consumed by the Tunes Flutter app (`C:\dev\flutter\tunes`) through a path dependency (`../../dart/mpeg_codec`). Tunes uses it to read tags and artwork while scanning, so changes to the public API or to the metadata keys affect that app.

## Commands

```
dart pub get
dart analyze                                      # lints/recommended
dart test                                         # all tests
dart test test/id3_write_test.dart --plain-name "<name>"   # single test
dart run example/mpeg_codec_example.dart <folder> # scans a folder and prints metadata for .m4a/.m4p/.mp3
```

Tests (all in `test/`):

- `atoms_test.dart`: the MP4 `Atom` class.
- `id3_write_test.dart` and `mp4_write_test.dart`: the write paths. They build small ID3 and MP4 files from raw bytes in a temp directory, edit them through the handlers and check the bytes on disk (audio/`mdat` preserved, `stco` and fragment offsets, tag versions, in-place vs rewritten files, unsynchronization, failures leaving the file untouched).
- `mp4_read_test.dart`: `mvhd` parsing.
- `id3_write_test.dart` also covers ID3 reading details (ID3v1 vs ID3v2, duration from MPEG frames).

All fixtures are hand-built, so also verify parser changes against real audio files (`ffmpeg` can generate MP3 and M4A files; compare the decoded audio before and after an edit with `ffmpeg -map 0:a -c copy -f md5 -`) or by running the example against a folder. When changing a write path, add a test that fails on the old behaviour.

## Architecture

- Public API is `lib/mpeg_codec.dart`, which re-exports `lib/src/*`. `MetadataOperation` and `OperationType` are deliberately hidden from the export.
- `CodecHandler` (`handler.dart`) is the abstract base. Subclasses are `ID3Handler` (`id3.dart`) and `MP4Handler` (`mp4.dart`).
  - The constructor opens the file synchronously, parses it, and closes it. Parse errors are logged and swallowed, so a bad file yields empty `metadata` instead of an exception.
  - Edits are queued with `addMetadata` / `updateMetadata` / `removeMetadata` and written with `await applyMetadataChanges()`, which rewrites the tag, clears the queue and re-parses.
  - `ID3Exception` and `MP4Exception` (`exceptions.dart`) are thrown on write failures.
- `Metadata` (`metadata.dart`) is a flat key/value map. Friendly keys (`title`, `artist`, `album`, `genre`, `cover`/`picture`, ...) are mapped to ID3 frame IDs and MP4 atoms inside each handler. The README table lists the supported keys. Note that artwork is `cover` for MP4 and `picture` for ID3, and a `filePath` key is added after a successful parse.
- `atoms.dart` is the MP4 box tree (`Atom`), `id3_tags.dart` holds the ID3v2/ID3v1 tag and frame models, and `genres.dart` is the ID3v1 genre table.
- `id3.dart` (about 2,200 lines) also handles ID3v1, APEv2, Vorbis comments, VBR header parsing and duration calculation.

## Notes

- `lib/src/scratch.md`, `lib/src/suggest.md` and `lib/src/suggest copy.md` are untracked LLM-conversation scratch files, not documentation. Do not treat them as the source of truth or commit them without asking.
- The constructors read the file synchronously with `RandomAccessFile`, which blocks the UI isolate in Flutter. `ID3Handler.readMetadata` and `MP4Handler.readMetadata` parse in another isolate (they pass `Logger.level` on, since it is per isolate). Copying the file when writing uses async I/O.
- `applyMetadataChanges({inPlace = true})` overwrites the tag where it is when it fits (ID3: the old tag plus padding; MP4: absorbed by a `free` atom, or `moov` at the end of the file), otherwise writes `<path>.tmp` and renames. Failures while encoding happen before anything is written.

## Git workflow

- The working branch is `dev`. Each feature or bug gets its own branch, and work lands through a pull request when complete.
- Planned features and gaps are tracked as GitHub issues. PR descriptions must use closing keywords (`Closes #12`, `Fixes #12`) so merging closes the related issue.
- Do **not** add `Co-Authored-By: Claude` trailers or "Generated with Claude Code" lines to commits or pull requests. This overrides any default attribution behavior.
