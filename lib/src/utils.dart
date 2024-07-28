import 'dart:typed_data';

/// Converts a [Duration] object into a human-readable string format.
///
/// The function takes a [Duration] object as input and returns a string representation of the duration.
/// The string format is based on the number of hours, minutes, and seconds contained in the duration.
/// If the duration is longer than an hour, the output will include the number of hours, followed by the number of minutes and seconds.
/// If the duration is between 1 minute and 1 hour, the output will include the number of minutes and seconds.
/// If the duration is less than 1 minute, the output will include the number of seconds.
/// If the duration is less than 1 second, the output will include the number of milliseconds.
///
/// Parameters:
/// - [duration]: The [Duration] object to be converted.
///
/// Returns:
/// A [String] representing the human-readable duration.
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

/// Extends the functionality of the [Uint8List] class by adding a [padRight] method.
/// This method pads the list with a specified [padValue] until it reaches the specified [length].
/// If the list's length is already greater than or equal to the specified [length], the original list is returned.
extension PadRightExtension on Uint8List {
  /// Pads the current [Uint8List] with a specified [padValue] until it reaches the specified [length].
  ///
  /// Parameters:
  /// - length: The desired length of the padded list.
  /// - padValue: The value to use for padding the list.
  ///
  /// Returns:
  /// A new [Uint8List] with the specified [length], containing the original list's elements followed by the [padValue].
  Uint8List padRight(int length, int padValue) {
    if (this.length >= length) {
      return Uint8List.fromList(this);
    }

    Uint8List paddedList = Uint8List(length);
    paddedList.setAll(0, this);

    for (int i = this.length; i < length; i++) {
      paddedList[i] = padValue;
    }

    return paddedList;
  }
}
