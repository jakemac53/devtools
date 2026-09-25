// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'package:devtools_app/src/screens/genui/catalog/json_column_data.dart';
import 'package:devtools_app/src/screens/genui/sources/default_registries.dart';
import 'package:devtools_app/src/screens/genui/sources/memory_sources.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jmespath/jmespath.dart' as jmespath;
import 'package:vm_service/vm_service.dart';

Map<String, Object?> _classStats({
  required String name,
  required String libraryUri,
  required int newCount,
  required int newSize,
  int newExternal = 0,
  int oldCount = 0,
  int oldSize = 0,
  int oldExternal = 0,
}) => {
  'type': 'ClassHeapStats',
  'class': {
    'type': '@Class',
    'id': 'classes/$name',
    'name': name,
    'library': {
      'type': '@Library',
      'id': 'libraries/$name',
      'name': '',
      'uri': libraryUri,
    },
  },
  'bytesCurrent': newSize + oldSize,
  'accumulatedSize': newSize + oldSize,
  'instancesCurrent': newCount + oldCount,
  'instancesAccumulated': newCount + oldCount,
  '_new': [newCount, newSize, newExternal],
  '_old': [oldCount, oldSize, oldExternal],
};

AllocationProfile _profile() => AllocationProfile.parse({
  'type': 'AllocationProfile',
  'memoryUsage': {
    'type': 'MemoryUsage',
    'externalUsage': 0,
    'heapCapacity': 0,
    'heapUsage': 0,
  },
  'members': [
    _classStats(
      name: 'MyWidget',
      libraryUri: 'package:my_app/widgets.dart',
      newCount: 3,
      newSize: 300,
      oldCount: 1,
      oldSize: 100,
    ),
    _classStats(
      name: 'String',
      libraryUri: 'dart:core',
      newCount: 50,
      newSize: 5000,
      newExternal: 10,
    ),
    _classStats(
      name: 'Unused',
      libraryUri: 'package:other/other.dart',
      newCount: 0,
      newSize: 0,
    ),
    _classStats(
      name: 'Dep',
      libraryUri: 'package:other/other.dart',
      newCount: 2,
      newSize: 40,
    ),
  ],
})!;

void main() {
  group('memory.classes', () {
    test('projects the allocation profile per class, sorted by size', () {
      final rows = projectAllocationProfile(
        _profile(),
        rootPackage: 'package:my_app',
      );

      // Classes without live instances are dropped.
      expect(rows.map((r) => r['class']), ['String', 'MyWidget', 'Dep']);

      expect(rows[0], {
        'class': 'String',
        'library': 'dart:core',
        'package': null,
        'classType': 'sdk',
        'instances': 50,
        'totalBytes': 5010,
        'dartHeapBytes': 5000,
        'externalBytes': 10,
        'newSpaceInstances': 50,
        'newSpaceBytes': 5010,
        'oldSpaceInstances': 0,
        'oldSpaceBytes': 0,
      });
      expect(rows[1], containsPair('classType', 'project'));
      expect(rows[1], containsPair('package', 'my_app'));
      expect(rows[1], containsPair('instances', 4));
      expect(rows[1], containsPair('oldSpaceInstances', 1));
      expect(rows[2], containsPair('classType', 'dependency'));
    });

    test('works with the documented example expressions', () {
      final rows = projectAllocationProfile(
        _profile(),
        rootPackage: 'package:my_app',
      );
      expect(jmespath.search("[?classType=='project'].class", rows), [
        'MyWidget',
      ]);
      expect(
        jmespath.search(
          '{classes: length(@), bytes: sum([].totalBytes), '
          'instances: sum([].instances)}',
          rows,
        ),
        {'classes': 3, 'bytes': 5450, 'instances': 56},
      );
    });

    test('is registered with an action and a table preset', () {
      final registries = GenUiRegistries.defaults();
      expect(registries.dataSources.lookup('memory.classes'), isNotNull);
      expect(registries.actions.lookup('memory.refreshClasses'), isNotNull);
      final preset = jsonColumnPresets['memory.classes']!;
      final fields = preset.map((c) => c['field']).toList();
      expect(fields, containsAll(['class', 'instances', 'totalBytes']));
      for (final column in preset) {
        expect(JsonColumnData.fromJson(column).field, column['field']);
      }
    });
  });
}
