import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:logger/logger.dart';

import 'atoms.dart';
import 'exceptions.dart';
import 'genres.dart';
import 'metadata.dart';

enum OperationType { add, update, remove }

class MetadataOperation {
  final OperationType type;
  final String key;
  final dynamic value;

  MetadataOperation(this.type, this.key, [this.value]);
}

abstract class CodecHandler {
  late RandomAccessFile file;
  late String _filePath;
  final Logger logger = Logger();
  final Metadata _metadata = Metadata();
  final List<MetadataOperation> pendingOperations = [];

  CodecHandler(String filePath) {
    _filePath = filePath;
  }

  void openRead() {
    file = File(_filePath).openSync(mode: FileMode.read);
  }

  void log(dynamic message) {
    logger.d(message);
  }

  void parseMetadata();

  Metadata get metadata => _metadata;

  T? getMetadata<T>(String key) => _metadata.get(key);
  void setMetadata(String key, dynamic value) => _metadata.set(key, value);

  Future<void> writeToFile(String outputPath);

  Future<void> applyMetadataChanges();

  void addMetadata(Map<String, dynamic> newMetadata) {
    for (var entry in newMetadata.entries) {
      pendingOperations.add(MetadataOperation(
        OperationType.add,
        entry.key,
        entry.value,
      ));
    }
  }

  void updateMetadata(Map<String, dynamic> newMetadata) {
    for (var entry in newMetadata.entries) {
      pendingOperations.add(MetadataOperation(
        OperationType.update,
        entry.key,
        entry.value,
      ));
    }
  }

  void removeMetadata(List<String> keys) {
    for (var key in keys) {
      pendingOperations.add(MetadataOperation(
        OperationType.remove,
        key,
      ));
    }
  }

  void clearPendingOperations() {
    pendingOperations.clear();
  }

  void close() {
    file.closeSync();
  }
}
