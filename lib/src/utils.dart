import 'dart:typed_data';

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

extension PadRightExtension on Uint8List {
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
