import 'dart:convert';

import 'package:toml/toml.dart';
import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

enum NetworkConfigFormat { properties, yaml, toml }

class NetworkConfigDocument {
  NetworkConfigDocument(this.format, this.text) {
    switch (format) {
      case NetworkConfigFormat.properties:
        _data = <String, Object?>{};
        for (final String line in const LineSplitter().convert(text)) {
          final RegExpMatch? match = _property.firstMatch(line);
          if (match == null) continue;
          final String key = match.group(1)!;
          final String value = match.group(2)!;
          if (value.endsWith(r'\')) {
            throw const FormatException('Continued properties are unsupported');
          }
          _data[key] = value;
        }
      case NetworkConfigFormat.yaml:
        final Object? yaml = loadYaml(text);
        if (yaml != null && yaml is! Map) {
          throw const FormatException('Configuration must be a mapping');
        }
        _data = yaml == null ? <String, Object?>{} : _map(yaml as Map);
        _editor = YamlEditor(text.trim().isEmpty ? '{}\n' : text);
      case NetworkConfigFormat.toml:
        _data = TomlDocument.parse(text).toMap();
    }
  }

  final NetworkConfigFormat format;
  final String text;
  late final Map<String, Object?> _data;
  YamlEditor? _editor;
  final Map<String, Object?> _propertyChanges = <String, Object?>{};
  static final RegExp _property = RegExp(
    r'^\s*([^#!\s:=]+)\s*(?:[=:]\s*|\s+)(.*)$',
  );

  static Map<String, Object?> _map(Map source) => <String, Object?>{
    for (final MapEntry<Object?, Object?> entry in source.entries)
      entry.key as String: _plain(entry.value),
  };

  static Object? _plain(Object? value) {
    if (value is Map) return _map(value);
    if (value is List) return value.map(_plain).toList();
    return value;
  }

  List<String> _path(String key) =>
      format == NetworkConfigFormat.properties ? <String>[key] : key.split('.');

  bool contains(String key) {
    Object? current = _data;
    for (final String segment in _path(key)) {
      if (current is! Map || !current.containsKey(segment)) return false;
      current = current[segment];
    }
    return true;
  }

  Object? value(String key) {
    Object? current = _data;
    for (final String segment in _path(key)) {
      if (current is! Map) return null;
      current = current[segment];
    }
    return current;
  }

  Map<String, Object?> snapshot(String key) {
    final List<String> segments = _path(key);
    final List<String> absentParents = <String>[];
    for (int count = 1; count < segments.length; count++) {
      final String parent = segments.take(count).join('.');
      if (!contains(parent)) absentParents.add(parent);
    }
    return <String, Object?>{
      'present': contains(key),
      'value': value(key),
      'absentParents': absentParents,
    };
  }

  void set(String key, Object? value) {
    final List<String> segments = _path(key);
    Map<String, Object?> parent = _data;
    for (int index = 0; index < segments.length - 1; index++) {
      final String segment = segments[index];
      if (!parent.containsKey(segment)) {
        parent[segment] = <String, Object?>{};
        _edit(
          () => _editor?.update(segments.take(index + 1), <String, Object?>{}),
        );
      }
      final Object? child = parent[segment];
      if (child is! Map<String, Object?>) {
        throw const FormatException(
          'Managed configuration parent is not a map',
        );
      }
      parent = child;
    }
    parent[segments.last] = value;
    _edit(() => _editor?.update(segments, value));
    if (format == NetworkConfigFormat.properties) _propertyChanges[key] = value;
  }

  void remove(String key) {
    if (!contains(key)) return;
    final List<String> segments = _path(key);
    Map<String, Object?> parent = _data;
    for (final String segment in segments.take(segments.length - 1)) {
      parent = parent[segment] as Map<String, Object?>;
    }
    parent.remove(segments.last);
    _edit(() => _editor?.remove(segments));
    if (format == NetworkConfigFormat.properties) _propertyChanges[key] = null;
  }

  void restore(String key, Map<String, Object?> snapshot) {
    if (snapshot['present'] == true) {
      set(key, snapshot['value']);
    } else {
      remove(key);
    }
    final List<String> absentParents =
        (snapshot['absentParents'] as List<Object?>).cast<String>();
    for (final String parent in absentParents.reversed) {
      final Object? current = value(parent);
      if (current is Map && current.isEmpty) remove(parent);
    }
  }

  void _edit(void Function() operation) {
    try {
      operation();
    } catch (_) {
      throw const FormatException(
        'Cannot edit YAML network settings. Use explicit mappings without YAML aliases for the managed settings.',
      );
    }
  }

  String render() {
    switch (format) {
      case NetworkConfigFormat.yaml:
        return _editor!.toString();
      case NetworkConfigFormat.toml:
        return TomlDocument.fromMap(_data).toString();
      case NetworkConfigFormat.properties:
        final List<String> lines = const LineSplitter().convert(text);
        final Set<String> written = <String>{};
        final List<String> result = <String>[];
        for (final String line in lines) {
          final String? key = _property.firstMatch(line)?.group(1);
          if (key == null || !_propertyChanges.containsKey(key)) {
            result.add(line);
          } else if (written.add(key) && _propertyChanges[key] != null) {
            result.add('$key=${_propertyChanges[key]}');
          }
        }
        for (final MapEntry<String, Object?> entry
            in _propertyChanges.entries) {
          if (written.add(entry.key) && entry.value != null) {
            result.add('${entry.key}=${entry.value}');
          }
        }
        return result.isEmpty ? '' : '${result.join('\n')}\n';
    }
  }
}
