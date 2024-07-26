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
