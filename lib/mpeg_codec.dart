/// A package for handling MP4 and ID3 metadata and related operations.
///
/// This package provides various modules for working with MP4 and ID3 metadata,
/// such as handling exceptions, managing genres, processing metadata, handling
/// MP4 and ID3 codecs.
library;

export 'src/exceptions.dart';
export 'src/genres.dart';
export 'src/handler.dart' hide MetadataOperation, OperationType;
export 'src/id3.dart';
export 'src/metadata.dart';
export 'src/mp4.dart';
export 'src/utils.dart';
