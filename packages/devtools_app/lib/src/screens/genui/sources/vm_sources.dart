// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'dart:async';

import 'package:json_schema_builder/json_schema_builder.dart';
import 'package:vm_service/vm_service.dart';

import '../../../shared/globals.dart';
import '../data/actions.dart';
import '../data/data_source.dart';
import '../data/json_utils.dart';
import '../data/ref_store.dart';

/// The `_ref` kind used for [IsolateRef]s.
const isolateRefKind = 'vm.isolate';

JsonObject _projectVm(VM? vm, List<IsolateRef> isolates) {
  if (vm == null) return {'connected': false};
  return {
    'connected': true,
    'name': vm.name,
    'version': vm.version,
    'operatingSystem': vm.operatingSystem,
    'targetCPU': vm.targetCPU,
    'hostCPU': vm.hostCPU,
    'architectureBits': vm.architectureBits,
    'pid': vm.pid,
    'startTime': vm.startTime,
    'isolateCount': isolates.length,
  };
}

JsonObject _projectIsolate(
  IsolateRef isolate,
  IsolateRef? selected,
  GenUiRefStore refs,
) => {
  if (isolate.id != null)
    refKey: refs.refFor(isolate, kind: isolateRefKind, id: isolate.id!),
  'id': isolate.id,
  'name': isolate.name,
  'number': isolate.number,
  'isSystemIsolate': isolate.isSystemIsolate,
  'selected': isolate.id == selected?.id,
};

/// Data sources describing the connected VM and its isolates.
List<DataSourceDescriptor> vmDataSources() => [
  DataSourceDescriptor(
    id: 'vm.info',
    description:
        'General information about the Dart VM of the connected app (the '
        'same data as the VM Tools screen header). `connected` is false when '
        'no app is connected.',
    paramsSchema: S.object(properties: {}),
    outputSchema: S.object(
      properties: {
        'connected': S.boolean(),
        'name': S.string(),
        'version': S.string(),
        'operatingSystem': S.string(),
        'targetCPU': S.string(),
        'hostCPU': S.string(),
        'architectureBits': S.integer(),
        'pid': S.integer(),
        'startTime': S.integer(description: 'Milliseconds since epoch.'),
        'isolateCount': S.integer(),
      },
    ),
    exampleExpressions: ['{VM: name, Version: version, OS: operatingSystem}'],
    open: (context, params) {
      final serviceManager = serviceConnection.serviceManager;
      final isolates = serviceManager.isolateManager.isolates;
      return streamFromListenables([
        serviceManager.connectedState,
        isolates,
      ], () => _projectVm(serviceManager.vm, isolates.value));
    },
  ),
  DataSourceDescriptor(
    id: 'vm.isolates',
    description: 'Live list of isolates in the connected app.',
    paramsSchema: S.object(properties: {}),
    outputSchema: S.list(
      items: S.object(
        properties: {
          refKey: S.string(description: 'Opaque handle to the isolate.'),
          'id': S.string(),
          'name': S.string(),
          'number': S.string(),
          'isSystemIsolate': S.boolean(),
          'selected': S.boolean(
            description: 'Whether this is the isolate selected in DevTools.',
          ),
        },
      ),
    ),
    exampleExpressions: ['[?!isSystemIsolate]', '[?selected] | [0]'],
    open: (context, params) {
      final isolateManager = serviceConnection.serviceManager.isolateManager;
      return streamFromListenables(
        [isolateManager.isolates, isolateManager.selectedIsolate],
        () => [
          for (final isolate in isolateManager.isolates.value)
            _projectIsolate(
              isolate,
              isolateManager.selectedIsolate.value,
              context.refs,
            ),
        ],
      );
    },
  ),
  DataSourceDescriptor(
    id: 'vm.isolateMemory',
    description:
        'Periodically polled Dart heap usage for every non-system isolate. '
        'Values are in bytes.',
    paramsSchema: S.object(
      properties: {
        'intervalMs': S.integer(
          description: 'Polling interval in milliseconds (default 2000).',
          minimum: 250,
        ),
      },
    ),
    outputSchema: S.list(
      items: S.object(
        properties: {
          'isolateId': S.string(),
          'name': S.string(),
          'heapUsage': S.integer(),
          'heapCapacity': S.integer(),
          'externalUsage': S.integer(),
          'timestamp': S.integer(description: 'Milliseconds since epoch.'),
        },
      ),
    ),
    exampleExpressions: ['[].{name: name, used: heapUsage}'],
    open: (context, params) {
      final interval = Duration(
        milliseconds: (params['intervalMs'] as num?)?.toInt() ?? 2000,
      );
      Timer? timer;
      late final StreamController<Object?> controller;
      Future<void> poll() async {
        final serviceManager = serviceConnection.serviceManager;
        final service = serviceManager.service;
        if (service == null) return;
        final now = DateTime.now().millisecondsSinceEpoch;
        final rows = <JsonObject>[];
        for (final isolate in serviceManager.isolateManager.isolates.value) {
          if (isolate.isSystemIsolate ?? false) continue;
          final id = isolate.id;
          if (id == null) continue;
          try {
            final usage = await service.getMemoryUsage(id);
            rows.add({
              'isolateId': id,
              'name': isolate.name,
              'heapUsage': usage.heapUsage,
              'heapCapacity': usage.heapCapacity,
              'externalUsage': usage.externalUsage,
              'timestamp': now,
            });
          } on SentinelException {
            // The isolate went away; skip it.
          }
        }
        if (!controller.isClosed) controller.add(rows);
      }

      controller = StreamController<Object?>(
        onListen: () {
          unawaited(poll());
          timer = Timer.periodic(interval, (_) => unawaited(poll()));
        },
        onCancel: () => timer?.cancel(),
      );
      return controller.stream;
    },
  ),
];

/// Actions that act on the connected VM / app.
List<ActionDescriptor> vmActions() => [
  ActionDescriptor(
    id: 'app.hotReload',
    description: 'Hot reloads the connected Flutter app.',
    mutatesApp: true,
    run: (context, args) async {
      await serviceConnection.serviceManager.performHotReload();
      return null;
    },
  ),
  ActionDescriptor(
    id: 'app.hotRestart',
    description: 'Hot restarts the connected Flutter app.',
    mutatesApp: true,
    run: (context, args) async {
      await serviceConnection.serviceManager.performHotRestart();
      return null;
    },
  ),
  ActionDescriptor(
    id: 'serviceExtension.set',
    description:
        'Sets the state of a service extension in the connected app, e.g. '
        '`ext.flutter.debugPaint` with enabled=true, value=true. Shares '
        'state with the toggles in the DevTools screens.',
    mutatesApp: true,
    argsSchema: S.object(
      properties: {
        'extension': S.string(description: 'The service extension name.'),
        'enabled': S.boolean(),
        'value': S.any(description: 'The value to pass to the extension.'),
      },
      required: ['extension', 'enabled'],
    ),
    run: (context, args) async {
      final extension = args['extension'];
      if (extension is! String) {
        throw GenUiDataException('`extension` must be a string.');
      }
      final enabled = args['enabled'] == true;
      await serviceConnection.serviceManager.serviceExtensionManager
          .setServiceExtensionState(
            extension,
            enabled: enabled,
            value: args.containsKey('value') ? args['value'] : enabled,
          );
      return {'extension': extension, 'enabled': enabled};
    },
  ),
];
