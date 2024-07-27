import 'dart:io';

import 'package:logger/logger.dart';

import 'metadata.dart';

enum OperationType { add, update, remove }

/// Represents an operation to be performed on metadata.
///
/// This class is used to encapsulate the details of a metadata operation,
/// such as adding, updating, or removing a key-value pair.
class MetadataOperation {
  /// The type of operation to be performed.
  final OperationType type;

  /// The key of the metadata to be operated on.
  final String key;

  /// The new value for the metadata if the operation is [OperationType.add] or [OperationType.update].
  /// This parameter is optional and can be omitted for [OperationType.remove].
  final dynamic value;

  /// Constructs a new [MetadataOperation] instance.
  ///
  /// [type] is the type of operation to be performed.
  /// [key] is the key of the metadata to be operated on.
  /// [value] is the new value for the metadata if the operation is [OperationType.add] or [OperationType.update].
  /// This parameter is optional and can be omitted for [OperationType.remove].
  MetadataOperation(this.type, this.key, [this.value]);
}

/// A base class for handling codec operations, such as reading, writing, and modifying metadata.
abstract class CodecHandler {
  late RandomAccessFile file;
  late String _filePath;
  final Logger logger = Logger();
  final Metadata _metadata = Metadata();
  final List<MetadataOperation> pendingOperations = [];

  /// Constructs a new instance of [CodecHandler].
  ///
  /// [filePath] is the path to the file to be handled.
  CodecHandler(String filePath) {
    _filePath = filePath;
  }

  /// Opens the file for reading.
  void openRead() {
    file = File(_filePath).openSync(mode: FileMode.read);
  }

  /// Parses the metadata from the file.
  void parseMetadata();

  /// Gets the metadata associated with the given key.
  ///
  /// [key] is the key of the metadata to retrieve.
  /// Returns the value associated with the key, or `null` if the key is not found.
  Metadata get metadata => _metadata;

  /// Gets the metadata associated with the given key.
  ///
  /// [key] is the key of the metadata to retrieve.
  /// Returns the value associated with the key, or `null` if the key is not found.
  T? getMetadata<T>(String key) => _metadata.get(key);

  /// Sets the metadata associated with the given key.
  ///
  /// [key] is the key of the metadata to set.
  /// [value] is the new value for the metadata.
  void setMetadata(String key, dynamic value) => _metadata.set(key, value);

  /// Writes the modified metadata to a new file.
  ///
  /// [outputPath] is the path to the new file where the modified metadata will be written.
  Future<void> writeToFile(String outputPath);

  /// Applies the pending metadata changes to the file.
  Future<void> applyMetadataChanges();

  /// Adds new metadata entries to the pending operations.
  ///
  /// [newMetadata] is a map containing the new metadata entries to be added.
  void addMetadata(Map<String, dynamic> newMetadata) {
    for (var entry in newMetadata.entries) {
      pendingOperations.add(MetadataOperation(
        OperationType.add,
        entry.key,
        entry.value,
      ));
    }
  }

  /// Updates existing metadata entries in the pending operations.
  ///
  /// [newMetadata] is a map containing the updated metadata entries to be applied.
  void updateMetadata(Map<String, dynamic> newMetadata) {
    for (var entry in newMetadata.entries) {
      pendingOperations.add(MetadataOperation(
        OperationType.update,
        entry.key,
        entry.value,
      ));
    }
  }

  /// Removes metadata entries from the pending operations.
  ///
  /// [keys] is a list of keys for the metadata entries to be removed.
  void removeMetadata(List<String> keys) {
    for (var key in keys) {
      pendingOperations.add(MetadataOperation(
        OperationType.remove,
        key,
      ));
    }
  }

  /// Clears all pending metadata operations.
  void clearPendingOperations() {
    pendingOperations.clear();
  }

  /// Closes the file.
  void close() {
    file.closeSync();
  }
}
