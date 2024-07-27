String formatDuration(Duration duration) {
  if (duration.inHours > 0) {
    return '${duration.inHours} hours, ${duration.inMinutes.remainder(60)} minutes, ${duration.inSeconds.remainder(60)} seconds';
  } else if (duration.inMinutes > 0) {
    return '${duration.inMinutes} minutes, ${duration.inSeconds.remainder(60)} seconds';
  } else if (duration.inSeconds > 0) {
    return '${duration.inSeconds} seconds';
  } else {
    return '${duration.inMilliseconds} milliseconds';
  }
}