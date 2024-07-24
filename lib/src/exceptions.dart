class MP4Exception implements Exception {
  final String message;
  MP4Exception(this.message);

  @override
  String toString() => 'MP4Exception: $message';
}