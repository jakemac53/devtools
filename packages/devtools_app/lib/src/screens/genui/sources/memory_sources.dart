// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'dart:async';
import 'dart:math' as math;

import 'package:devtools_shared/devtools_shared.dart';
import 'package:flutter/foundation.dart';
import 'package:json_schema_builder/json_schema_builder.dart';
import 'package:vm_service/vm_service.dart';

import '../../../shared/globals.dart';
import '../../../shared/memory/class_name.dart';
import '../../memory/framework/memory_controller.dart';
import '../../memory/panes/profile/model.dart';
import '../data/actions.dart';
import '../data/data_source.dart';
import '../data/json_utils.dart';

MemoryController get _controller =>
    screenControllers.lookup<MemoryController>();

/// Bumped to ask every open `memory.classes` source to re-fetch.
final _classesRefreshRequests = ValueNotifier<int>(0);
void _requestClassesRefresh() => _classesRefreshRequests.value++;

JsonObject _projectHeapSample(HeapSample sample) => {
  'timestamp': sample.timestamp,
  'rss': sample.rss,
  'capacity': sample.capacity,
  'used': sample.used,
  'external': sample.external,
  'isGC': sample.isGC,
};

String _classTypeName(ClassType type) => switch (type) {
  ClassType.runtime => 'runtime',
  ClassType.sdk => 'sdk',
  ClassType.dependency => 'dependency',
  ClassType.rootPackage => 'project',
};

String? _packageOf(String library) {
  const prefix = 'package:';
  if (!library.startsWith(prefix)) return null;
  final slash = library.indexOf('/');
  return slash == -1
      ? library.substring(prefix.length)
      : library.substring(prefix.length, slash);
}

/// Projects a per-class [ProfileRecord] (the same model the Memory screen's
/// "Profile Memory" tab uses) into a JSON row.
@visibleForTesting
JsonObject projectProfileRecord(ProfileRecord record, {String? rootPackage}) {
  final heapClass = record.heapClass;
  return {
    'class': heapClass.shortName,
    'library': heapClass.library,
    'package': _packageOf(heapClass.library),
    'classType': _classTypeName(heapClass.classType(rootPackage)),
    'instances': record.totalInstances ?? 0,
    'totalBytes': record.totalSize,
    'dartHeapBytes': record.totalDartHeapSize,
    'externalBytes': record.totalExternalSize,
    'newSpaceInstances': record.newSpaceInstances ?? 0,
    'newSpaceBytes': record.newSpaceSize ?? 0,
    'oldSpaceInstances': record.oldSpaceInstances ?? 0,
    'oldSpaceBytes': record.oldSpaceSize ?? 0,
  };
}

/// Projects an [AllocationProfile] into one row per class with live
/// instances, sorted by total size, largest first.
@visibleForTesting
List<JsonObject> projectAllocationProfile(
  AllocationProfile profile, {
  String? rootPackage,
}) {
  final rows = [
    for (final stats in profile.members ?? const <ClassHeapStats>[])
      if ((stats.instancesCurrent ?? 0) > 0)
        projectProfileRecord(
          ProfileRecord.fromClassHeapStats(stats),
          rootPackage: rootPackage,
        ),
  ];
  rows.sort(
    (a, b) => (b['totalBytes'] as int).compareTo(a['totalBytes'] as int),
  );
  return rows;
}

Future<List<JsonObject>> _fetchClassRows({
  String? isolateId,
  bool gc = false,
}) async {
  final serviceManager = serviceConnection.serviceManager;
  final service = serviceManager.service;
  if (service == null) {
    throw GenUiDataException('Not connected to an app.');
  }
  final id =
      isolateId ?? serviceManager.isolateManager.selectedIsolate.value?.id;
  if (id == null) throw GenUiDataException('No isolate is selected.');
  final profile = await service.getAllocationProfile(id, gc: gc);
  return projectAllocationProfile(
    profile,
    rootPackage: serviceManager.rootInfoNow().package,
  );
}

/// Data sources backed by the [MemoryController] and the VM's allocation
/// profile.
List<DataSourceDescriptor> memoryDataSources() => [
  DataSourceDescriptor(
    id: 'memory.heapSamples',
    description:
        'Live time series of Dart heap and process memory samples for the '
        'connected app (the same data as the Memory screen chart). Values '
        'are in bytes; timestamps are milliseconds since epoch. Requires the '
        'Memory chart to be enabled in DevTools preferences.',
    paramsSchema: S.object(
      properties: {
        'limit': S.integer(
          description: 'Maximum number of most recent samples to emit.',
          minimum: 1,
          maximum: 5000,
        ),
      },
    ),
    outputSchema: S.list(
      items: S.object(
        properties: {
          'timestamp': S.integer(),
          'rss': S.integer(description: 'Resident set size of the process.'),
          'capacity': S.integer(description: 'Dart heap capacity.'),
          'used': S.integer(description: 'Dart heap used.'),
          'external': S.integer(description: 'External memory.'),
          'isGC': S.boolean(description: 'Whether a GC occurred.'),
        },
      ),
    ),
    exampleExpressions: ['[-1]', '[].{timestamp: timestamp, used: used}'],
    open: (context, params) async* {
      final limit = (params['limit'] as num?)?.toInt() ?? 300;
      final controller = _controller;
      await controller.initialized;
      final timeline = controller.chart.data.timeline;
      yield* streamFromListenable(timeline.sampleAdded, (_) {
        final data = timeline.data;
        final start = math.max(0, data.length - limit);
        return [for (final s in data.sublist(start)) _projectHeapSample(s)];
      });
    },
  ),
  DataSourceDescriptor(
    id: 'memory.classes',
    description:
        'Per-class memory usage (live instance counts and sizes) for an '
        'isolate of the connected app, from the VM allocation profile (the '
        'same data as the Memory screen "Profile Memory" tab). One row per '
        'class with live instances, sorted by totalBytes descending. Sizes '
        'are shallow sizes in bytes. `classType` is one of runtime, sdk, '
        'dependency, or project (classes from the app\'s own package). '
        'Re-fetched when opened, on the `memory.refreshClasses` and '
        '`memory.gc` actions, and every `intervalMs` if set.',
    paramsSchema: S.object(
      properties: {
        'intervalMs': S.integer(
          description:
              'Optional polling interval in milliseconds. Omit to only '
              'refresh on demand.',
          minimum: 1000,
        ),
        'gc': S.boolean(
          description:
              'Whether to run a full GC before each sample so that only '
              'reachable objects are counted (default false).',
        ),
        'isolateId': S.string(
          description: 'Isolate to profile. Defaults to the selected isolate.',
        ),
      },
    ),
    outputSchema: S.list(
      items: S.object(
        properties: {
          'class': S.string(),
          'library': S.string(description: 'Library name or uri.'),
          'package': S.string(
            description: 'Package name for `package:` libraries, else null.',
          ),
          'classType': S.string(
            enumValues: ['runtime', 'sdk', 'dependency', 'project'],
          ),
          'instances': S.integer(),
          'totalBytes': S.integer(
            description: 'dartHeapBytes + externalBytes.',
          ),
          'dartHeapBytes': S.integer(),
          'externalBytes': S.integer(),
          'newSpaceInstances': S.integer(),
          'newSpaceBytes': S.integer(),
          'oldSpaceInstances': S.integer(),
          'oldSpaceBytes': S.integer(),
        },
      ),
    ),
    exampleExpressions: [
      '[:20]',
      "[?classType=='project']",
      "[?contains(class, 'Widget')] | sort_by(@, &instances) | reverse(@)",
      '{classes: length(@), bytes: sum([].totalBytes)}',
    ],
    open: (context, params) {
      final intervalMs = (params['intervalMs'] as num?)?.toInt();
      final gc = params['gc'] == true;
      final isolateId = params['isolateId'] as String?;

      Timer? timer;
      var fetching = false;
      var refetch = false;
      late final StreamController<Object?> controller;

      Future<void> fetch() async {
        if (fetching) {
          refetch = true;
          return;
        }
        fetching = true;
        try {
          final rows = await _fetchClassRows(isolateId: isolateId, gc: gc);
          if (!controller.isClosed) controller.add(rows);
        } catch (e, st) {
          if (!controller.isClosed) controller.addError(e, st);
        } finally {
          fetching = false;
          if (refetch && !controller.isClosed) {
            refetch = false;
            unawaited(fetch());
          }
        }
      }

      void onRefreshRequested() => unawaited(fetch());

      controller = StreamController<Object?>(
        onListen: () {
          _classesRefreshRequests.addListener(onRefreshRequested);
          unawaited(fetch());
          if (intervalMs != null) {
            timer = Timer.periodic(
              Duration(milliseconds: math.max(1000, intervalMs)),
              (_) => unawaited(fetch()),
            );
          }
        },
        onCancel: () {
          _classesRefreshRequests.removeListener(onRefreshRequested);
          timer?.cancel();
        },
      );
      return controller.stream;
    },
  ),
];

/// Actions backed by the [MemoryController].
List<ActionDescriptor> memoryActions() => [
  ActionDescriptor(
    id: 'memory.gc',
    description:
        'Triggers a full garbage collection in the selected isolate of the '
        'connected app, then refreshes any `memory.classes` sources.',
    mutatesApp: true,
    run: (context, args) async {
      final controller = _controller;
      await controller.initialized;
      await controller.gc();
      _requestClassesRefresh();
      return null;
    },
  ),
  ActionDescriptor(
    id: 'memory.refreshClasses',
    description:
        'Re-fetches the per-class allocation profile for all open '
        '`memory.classes` sources. Does not change the app.',
    run: (context, args) async {
      _requestClassesRefresh();
      return null;
    },
  ),
];
