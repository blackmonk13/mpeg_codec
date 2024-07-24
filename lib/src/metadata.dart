class Metadata {
  final Map<String, dynamic> _data = {};

  void set(String key, dynamic value) => _data[key] = value;
  T? get<T>(String key) => _data[key] as T?;
  bool contains(String key) => _data.containsKey(key);
  Map<String, dynamic> asMap() => Map.unmodifiable(_data);

  @override
  String toString() => _data.toString();
}