/// This class represents an exception that can be thrown when an error occurs during the processing of MP4 files.
class MP4Exception implements Exception {
  /// A message describing the exception.
  final String message;

  /// Constructs a new [MP4Exception] with the given [message].
  MP4Exception(this.message);

  /// Returns a string representation of the exception.
  /// The returned string includes the class name and the [message].
  @override
  String toString() => 'MP4Exception: $message';
}

/// This class represents an exception that can be thrown when an error occurs during the processing of ID3 tags.
class ID3Exception implements Exception {
  /// A message describing the exception.
  final String message;

  /// Constructs a new [ID3Exception] with the given [message].
  ID3Exception(this.message);

  /// Returns a string representation of the exception.
  /// The returned string includes the class name and the [message].
  @override
  String toString() => 'ID3Exception: $message';
}
