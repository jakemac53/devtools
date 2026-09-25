// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'package:devtools_app/src/screens/genui/catalog/json_column_data.dart';
import 'package:devtools_app/src/screens/genui/sources/cpu_sources.dart';
import 'package:devtools_app/src/screens/genui/sources/default_registries.dart';
import 'package:devtools_app/src/screens/profiler/cpu_profile_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jmespath/jmespath.dart' as jmespath;

const _isolate = '1234';

Map<String, Object?> _frame(
  String name, {
  required String parent,
  String packageUri = '',
  int? line,
}) => {
  'category': 'Dart',
  'name': name,
  'parent': parent == CpuProfileData.rootId ? parent : '$_isolate-$parent',
  'resolvedUrl': packageUri,
  'packageUri': packageUri,
  'sourceLine': line,
};

Map<String, Object?> _sample(int ts, String leaf, {String tag = 'Default'}) => {
  'ph': 'P',
  'name': '',
  'pid': 1,
  'tid': 1,
  'ts': ts,
  'cat': 'Dart',
  'sf': '$_isolate-$leaf',
  'args': {'userTag': tag, 'vmTag': 'Dart'},
};

/// Call tree:
///
///     main (my_app)
///       build (flutter)
///         nativeThing (native)
///         main (my_app, recursive)
///       List.add (dart:core)
CpuProfileData _profile() => CpuProfileData.fromJson({
  'type': '_CpuProfileTimeline',
  'samplePeriod': 1000,
  'sampleCount': 5,
  'stackDepth': 128,
  'timeOriginMicros': 0,
  'timeExtentMicros': 5000,
  'stackFrames': {
    '$_isolate-1': _frame(
      'main',
      parent: CpuProfileData.rootId,
      packageUri: 'package:my_app/main.dart',
      line: 10,
    ),
    '$_isolate-2': _frame(
      'build',
      parent: '1',
      packageUri: 'package:flutter/src/widgets/framework.dart',
      line: 20,
    ),
    '$_isolate-3': _frame('nativeThing', parent: '2'),
    '$_isolate-4': _frame(
      'main',
      parent: '2',
      packageUri: 'package:my_app/main.dart',
      line: 10,
    ),
    '$_isolate-5': _frame(
      'List.add',
      parent: '1',
      packageUri: 'dart:core/growable_array.dart',
      line: 30,
    ),
  },
  'traceEvents': [
    _sample(0, '3'),
    _sample(1000, '3'),
    _sample(2000, '4', tag: 'Build'),
    _sample(3000, '2'),
    _sample(4000, '5'),
  ],
});

List<Object?> _names(List<Map<String, Object?>> rows) =>
    rows.map((r) => r['name']).toList();

void main() {
  group('projectCpuFunctions', () {
    test('computes self and total samples per function', () {
      final data = _profile();
      final rows = projectCpuFunctions(data, rootPackage: 'package:my_app');
      expect(_names(rows), ['nativeThing', 'main', 'build', 'List.add']);

      final byName = {for (final r in rows) r['name']: r};
      expect(byName['nativeThing'], containsPair('selfSamples', 2));
      expect(byName['nativeThing'], containsPair('selfPct', 0.4));
      expect(byName['nativeThing'], containsPair('category', 'native'));
      expect(byName['nativeThing'], containsPair('package', null));

      // Recursive frames are only counted once per sample.
      expect(byName['main'], containsPair('totalSamples', 5));
      expect(byName['main'], containsPair('totalPct', 1.0));
      expect(byName['main'], containsPair('selfSamples', 1));
      expect(byName['main'], containsPair('category', 'app'));
      expect(byName['main'], containsPair('package', 'my_app'));
      expect(byName['main'], containsPair('line', 10));

      expect(byName['build'], containsPair('totalSamples', 4));
      expect(byName['build'], containsPair('category', 'flutter'));
      expect(byName['List.add'], containsPair('category', 'dart'));
      expect(byName['List.add'], containsPair('package', 'dart:core'));

      final period = data.profileMetaData.samplePeriod;
      expect(byName['nativeThing']!['selfMs'], 2 * period / 1000);
    });

    test('attributes native time to callers when excluding native', () {
      final rows = projectCpuFunctions(_profile(), includeNative: false);
      expect(_names(rows), ['build', 'main', 'List.add']);
      expect(rows.first, containsPair('selfSamples', 3));
    });

    test('filters by user tag and limits rows', () {
      final rows = projectCpuFunctions(_profile(), userTag: 'Build');
      expect(_names(rows), ['main', 'build']);
      expect(rows.first, containsPair('totalPct', 1.0));
      expect(projectCpuFunctions(_profile(), limit: 2), hasLength(2));
    });

    test('handles an empty profile', () {
      expect(projectCpuFunctions(CpuProfileData.empty()), isEmpty);
    });

    test('works with the documented example expressions', () {
      final rows = projectCpuFunctions(
        _profile(),
        rootPackage: 'package:my_app',
      );
      expect(jmespath.search("[?category=='app'].name", rows), ['main']);
      expect(
        jmespath.search(
          'sort_by(@, &totalSamples) | reverse(@) | [:1].name',
          rows,
        ),
        ['main'],
      );
      expect(
        jmespath.search("[?package=='flutter'] | sum([].selfPct)", rows),
        0.2,
      );
    });
  });

  group('projectCpuActivity', () {
    test('buckets samples by time and category', () {
      final rows = projectCpuActivity(
        _profile(),
        bucketMs: 2,
        rootPackage: 'my_app',
      );
      expect(rows.map((r) => r['timestamp']), [0, 2, 4]);
      expect(rows.map((r) => r['samples']), [2, 2, 1]);
      expect(rows[0], containsPair('native', 2));
      expect(rows[1], containsPair('app', 1));
      expect(rows[1], containsPair('flutter', 1));
      expect(rows[1], containsPair('byUserTag', {'Build': 1, 'Default': 1}));
      expect(rows[2], containsPair('dart', 1));
      for (final row in rows) {
        expect(row.keys, containsAll(cpuCategories));
        expect(row['cpuPct'] as double, inInclusiveRange(0, 1));
      }
    });

    test('offsets timestamps and fills idle buckets', () {
      final rows = projectCpuActivity(
        _profile(),
        bucketMs: 2,
        epochOffsetMicros: 10000,
        startMicros: 0,
        endMicros: 9000,
      );
      expect(rows.map((r) => r['timestamp']), [10, 12, 14, 16, 18]);
      expect(rows.map((r) => r['samples']), [2, 2, 1, 0, 0]);
      expect(rows.last, containsPair('cpuPct', 0.0));
    });
  });

  test('CPU sources, actions, and preset are registered', () {
    final registries = GenUiRegistries.defaults();
    for (final id in ['cpu.functions', 'cpu.activity', 'cpu.status']) {
      expect(registries.dataSources.lookup(id), isNotNull, reason: id);
    }
    for (final id in ['cpu.startRecording', 'cpu.stopRecording', 'cpu.clear']) {
      final action = registries.actions.lookup(id);
      expect(action, isNotNull, reason: id);
      expect(action!.mutatesApp, isFalse, reason: id);
    }
    final preset = jsonColumnPresets['cpu.functions']!;
    for (final column in preset) {
      expect(JsonColumnData.fromJson(column).field, column['field']);
    }
  });
}
