import 'dart:typed_data';

import 'package:collection/collection.dart';

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



extension Uint8Utils on Uint8List {
  bool equals(Uint8List other) {
    return ListEquality<int>().equals(other, this);
  }

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