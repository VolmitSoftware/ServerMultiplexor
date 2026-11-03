import 'dart:io';

import 'package:path/path.dart' as p;

/// The `\\?\` form of [path] on Windows, returned unchanged elsewhere.
///
/// `Directory.listSync` fails with "Directory listing failed" once a directory
/// path passes 260 characters, while Dart's other file operations already
/// handle long paths. Plugin library folders routinely go that deep.
String extendedLengthPath(String path) {
  if (!Platform.isWindows || path.startsWith(r'\\?\')) return path;
  final String absolute = p.normalize(p.absolute(path));
  return absolute.startsWith(r'\\')
      ? '\\\\?\\UNC\\${absolute.substring(2)}'
      : '\\\\?\\$absolute';
}
