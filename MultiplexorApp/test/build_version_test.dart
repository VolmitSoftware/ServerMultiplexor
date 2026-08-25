import 'package:test/test.dart';

import '../tool/resolve_build_version.dart';

void main() {
  group('resolveBuildVersion', () {
    test('increments the source patch by the workflow run number', () {
      expect(
        resolveBuildVersion(sourceVersion: '0.2.0', runNumber: 37),
        '0.2.37',
      );
      expect(
        resolveBuildVersion(sourceVersion: '1.4.8', runNumber: 3),
        '1.4.11',
      );
    });

    test('uses a matching release tag exactly', () {
      expect(
        resolveBuildVersion(sourceVersion: '1.4.8', tag: 'v1.4.8'),
        '1.4.8',
      );
    });

    test('rejects a release tag that disagrees with source', () {
      expect(
        () => resolveBuildVersion(sourceVersion: '1.4.8', tag: 'v1.4.9'),
        throwsFormatException,
      );
    });

    test('requires a positive run number for non-release builds', () {
      expect(
        () => resolveBuildVersion(sourceVersion: '1.4.8', runNumber: 0),
        throwsFormatException,
      );
    });
  });
}
