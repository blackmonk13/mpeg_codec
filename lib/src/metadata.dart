/// A class representing metadata information.
class Metadata {
  /// A private map to store the metadata.
  final Map<String, dynamic> _data = {};

  /// Sets the value for the given key in the metadata.
  ///
  /// [key]: The key for which the value is to be set.
  /// [value]: The value to be associated with the given key.
  void set(String key, dynamic value) => _data[key] = value;

  /// Retrieves the value associated with the given key.
  ///
  /// [key]: The key for which the value is to be retrieved.
  ///
  /// Returns: The value associated with the given key, or `null` if the key is not found.
  T? get<T>(String key) {
    final value = _data[key];
    return value is T ? value : null;
  }

  /// Checks if the metadata contains the given key.
  ///
  /// [key]: The key to be checked.
  ///
  /// Returns: `true` if the metadata contains the given key, otherwise `false`.
  /// Removes all entries.
  void clear() => _data.clear();

  bool contains(String key) => _data.containsKey(key);

  /// Returns an unmodifiable view of the metadata as a map.
  ///
  /// Returns: An unmodifiable view of the metadata as a map.
  Map<String, dynamic> asMap() => Map.unmodifiable(_data);

  /// Returns a string representation of the metadata.
  ///
  /// Returns: A string representation of the metadata.
  @override
  String toString() => _data.toString();
}
