// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:json_schema_builder/json_schema_builder.dart';
import 'package:vm_service/vm_service.dart';

import '../../../shared/globals.dart';
import '../../profiler/cpu_profile_model.dart';
import '../../profiler/cpu_profiler_controller.dart';
import '../../profiler/profiler_screen_controller.dart';
import '../data/actions.dart';
import '../data/data_source.dart';
import '../data/json_utils.dart';

ProfilerScreenController get _controller =>
    screenControllers.lookup<ProfilerScreenController>();

/// Where CPU samples come from.
enum _CpuWindow {
  /// A rolling window of the most recent samples, pulled from the VM's sample
  /// buffer (no recording required).
  live,

  /// The last profile recorded with `cpu.startRecording`/`cpu.stopRecording`
  /// (the same profile the CPU Profiler screen shows).
  recording,
}

/// The coarse category of a stack frame, used to group CPU activity.
///
/// One of `app` (the connected app's own package), `flutter` (Flutter
/// framework, engine, and `dart:ui`), `dart` (Dart core libraries), `native`,
/// or `other` (any other package).
///
/// [rootPackage] is the app's root package, either as a uri prefix like
/// `package:my_app` (the form `RootInfo.package` uses) or a bare name.
@visibleForTesting
String cpuFrameCategory(CpuStackFrame frame, {String? rootPackage}) {
  if (frame.isNative) return 'native';
  if (frame.isFlutterCore) return 'flutter';
  if (frame.isDartCore) return 'dart';
  if (rootPackage != null && rootPackage.isNotEmpty) {
    final prefix = rootPackage.contains(':')
        ? rootPackage
        : 'package:$rootPackage';
    if (frame.packageUri.startsWith('$prefix/')) return 'app';
  }
  return 'other';
}

/// The categories reported by [cpuFrameCategory], in display order.
const cpuCategories = ['app', 'flutter', 'dart', 'native', 'other'];

String? _packageOf(String uri) {
  const packagePrefix = 'package:';
  if (uri.startsWith(packagePrefix)) {
    final slash = uri.indexOf('/');
    return slash == -1
        ? uri.substring(packagePrefix.length)
        : uri.substring(packagePrefix.length, slash);
  }
  if (uri.startsWith('dart:')) {
    final slash = uri.indexOf('/');
    return slash == -1 ? uri : uri.substring(0, slash);
  }
  return null;
}

bool _isSynthetic(CpuStackFrame frame) =>
    frame.id == CpuProfileData.rootId || frame.isTag;

/// Returns the frames of the stack for [sample], leaf first, excluding the
/// synthetic root and tag frames.
Iterable<CpuStackFrame> _stackOf(
  CpuProfileData data,
  CpuSampleEvent sample,
) sync* {
  var frame = data.stackFrames[sample.leafId];
  // Guard against malformed (cyclic) parent chains.
  var remaining = data.stackFrames.length + 1;
  while (frame != null && remaining-- > 0) {
    if (!_isSynthetic(frame)) yield frame;
    final parentId = frame.parentId;
    if (parentId == null) break;
    frame = data.stackFrames[parentId];
  }
}

Iterable<CpuSampleEvent> _samplesFor(CpuProfileData data, String? userTag) =>
    userTag == null
    ? data.cpuSamples
    : data.cpuSamples.where((s) => s.userTag == userTag);

/// Aggregates [data] into one row per function, like the CPU Profiler's
/// method table.
///
/// `selfSamples` counts samples where the function was on top of the stack;
/// `totalSamples` counts samples where it was anywhere on the stack (counted
/// once per sample, even if recursive). Percentages are ratios (0..1) of the
/// total number of (filtered) samples. Rows are sorted by `selfSamples`, then
/// `totalSamples`, descending.
///
/// If [includeNative] is false, native frames are skipped and their self time
/// is attributed to the nearest non-native caller.
@visibleForTesting
List<JsonObject> projectCpuFunctions(
  CpuProfileData data, {
  String? userTag,
  bool includeNative = true,
  String? rootPackage,
  int? limit,
}) {
  final samplePeriodMicros = data.profileMetaData.samplePeriod;
  final stats = <String, _FunctionStats>{};
  var sampleCount = 0;
  for (final sample in _samplesFor(data, userTag)) {
    sampleCount++;
    final seen = <String>{};
    var isLeaf = true;
    for (final frame in _stackOf(data, sample)) {
      if (!includeNative && frame.isNative) continue;
      final key = '${frame.name}|${frame.packageUri}|${frame.sourceLine}';
      final entry = stats.putIfAbsent(key, () => _FunctionStats(frame));
      if (isLeaf) {
        entry.self++;
        isLeaf = false;
      }
      if (seen.add(key)) entry.total++;
    }
  }

  double pct(int count) => sampleCount == 0 ? 0 : count / sampleCount;
  double ms(int count) => count * samplePeriodMicros / 1000;

  final rows = stats.values.toList()
    ..sort((a, b) {
      final bySelf = b.self.compareTo(a.self);
      return bySelf != 0 ? bySelf : b.total.compareTo(a.total);
    });
  return [
    for (final s in limit == null ? rows : rows.take(limit))
      {
        'name': s.frame.name,
        'package': _packageOf(s.frame.packageUri),
        'url': s.frame.packageUri,
        'line': s.frame.sourceLine,
        'category': cpuFrameCategory(s.frame, rootPackage: rootPackage),
        'selfSamples': s.self,
        'totalSamples': s.total,
        'selfPct': pct(s.self),
        'totalPct': pct(s.total),
        'selfMs': ms(s.self),
        'totalMs': ms(s.total),
      },
  ];
}

class _FunctionStats {
  _FunctionStats(this.frame);

  final CpuStackFrame frame;
  int self = 0;
  int total = 0;
}

/// Buckets the samples in [data] by time.
///
/// Each row is `{timestamp, samples, cpuPct, app, flutter, dart, native,
/// other, byUserTag}`. `timestamp` is the bucket start in milliseconds since
/// epoch, computed by adding [epochOffsetMicros] to the VM's sample
/// timestamps. The category fields count samples by the [cpuFrameCategory] of
/// the top-most frame. `cpuPct` estimates how busy the isolate's thread was in
/// the bucket (samples * sample period / bucket duration, clamped to 0..1).
///
/// When [startMicros] and [endMicros] (VM time) are given, empty buckets in
/// that range are included so that idle time shows up as zeros.
@visibleForTesting
List<JsonObject> projectCpuActivity(
  CpuProfileData data, {
  required int bucketMs,
  int epochOffsetMicros = 0,
  String? rootPackage,
  String? userTag,
  int? startMicros,
  int? endMicros,
}) {
  final bucketMicros = bucketMs * 1000;
  final samplePeriodMicros = data.profileMetaData.samplePeriod;
  final buckets = <int, _Bucket>{};

  int bucketOf(int vmMicros) => (vmMicros + epochOffsetMicros) ~/ bucketMicros;

  if (startMicros != null && endMicros != null && endMicros >= startMicros) {
    final first = bucketOf(startMicros);
    final last = bucketOf(endMicros);
    // Avoid pathological ranges.
    if (last - first <= 10000) {
      for (var b = first; b <= last; b++) {
        buckets[b] = _Bucket();
      }
    }
  }

  for (final sample in _samplesFor(data, userTag)) {
    final ts = sample.timestampMicros;
    if (ts == null) continue;
    final bucket = buckets.putIfAbsent(bucketOf(ts), _Bucket.new);
    bucket.samples++;
    final leaf = _stackOf(data, sample).firstOrNull;
    final category = leaf == null
        ? 'other'
        : cpuFrameCategory(leaf, rootPackage: rootPackage);
    bucket.byCategory[category] = (bucket.byCategory[category] ?? 0) + 1;
    final tag = sample.userTag ?? 'Default';
    bucket.byUserTag[tag] = (bucket.byUserTag[tag] ?? 0) + 1;
  }

  final keys = buckets.keys.toList()..sort();
  return [
    for (final key in keys)
      {
        'timestamp': key * bucketMs,
        'samples': buckets[key]!.samples,
        'cpuPct': math.min(
          1.0,
          buckets[key]!.samples * samplePeriodMicros / bucketMicros,
        ),
        for (final category in cpuCategories)
          category: buckets[key]!.byCategory[category] ?? 0,
        'byUserTag': buckets[key]!.byUserTag,
      },
  ];
}

class _Bucket {
  int samples = 0;
  final byCategory = <String, int>{};
  final byUserTag = <String, int>{};
}

/// A snapshot of CPU samples plus what's needed to interpret its timestamps.
class _CpuSnapshot {
  _CpuSnapshot(
    this.data, {
    required this.epochOffsetMicros,
    this.startMicros,
    this.endMicros,
  });

  final CpuProfileData data;
  final int epochOffsetMicros;
  final int? startMicros;
  final int? endMicros;
}

Future<VmService> _checkedService() async {
  final serviceManager = serviceConnection.serviceManager;
  final service = serviceManager.service;
  if (service == null) throw GenUiDataException('Not connected to an app.');
  if (await serviceManager.connectedApp?.isDartWebApp ?? false) {
    throw GenUiDataException(
      'CPU profiling is not available for Dart web apps.',
    );
  }
  return service;
}

/// Returns (epoch micros - VM timeline micros) and the VM timeline "now".
Future<(int, int)> _clockOffset(VmService service) async {
  final vmNow = (await service.getVMTimelineMicros()).timestamp!;
  return (DateTime.now().microsecondsSinceEpoch - vmNow, vmNow);
}

Future<_CpuSnapshot> _fetchLiveSnapshot({
  required int lastMs,
  String? isolateId,
}) async {
  final service = await _checkedService();
  final id =
      isolateId ??
      serviceConnection.serviceManager.isolateManager.selectedIsolate.value?.id;
  if (id == null) throw GenUiDataException('No isolate is selected.');
  final (offset, vmNow) = await _clockOffset(service);
  final extent = lastMs * 1000;
  final start = vmNow - extent;
  final CpuSamples samples;
  try {
    samples = await service.getCpuSamples(id, start, extent);
  } on RPCError catch (e) {
    throw GenUiDataException(
      'Could not get CPU samples: ${e.details ?? e.message}. Is the CPU '
      'profiler enabled (see the CPU Profiler screen or `cpu.startRecording`)?',
    );
  }
  final data = await CpuProfileData.generateFromCpuSamples(
    isolateId: id,
    cpuSamples: samples,
  );
  return _CpuSnapshot(
    data,
    epochOffsetMicros: offset,
    startMicros: start,
    endMicros: vmNow,
  );
}

Future<_CpuSnapshot?> _recordingSnapshot() async {
  final controller = _controller;
  await controller.initialized;
  final data = controller.cpuProfileData;
  // Null while a profile is being fetched or processed.
  if (data == null) return null;
  if (data.isEmpty) {
    return _CpuSnapshot(data, epochOffsetMicros: 0);
  }
  final service = await _checkedService();
  final (offset, _) = await _clockOffset(service);
  return _CpuSnapshot(
    data,
    epochOffsetMicros: offset,
    startMicros: data.profileMetaData.time?.start,
    endMicros: data.profileMetaData.time?.end,
  );
}

/// Opens a stream of projected CPU data for the shared window params.
Stream<Object?> _openCpuSource(
  JsonObject params,
  Object? Function(_CpuSnapshot snapshot) project,
) {
  final window = params['window'] == 'recording'
      ? _CpuWindow.recording
      : _CpuWindow.live;
  final lastMs = ((params['lastMs'] as num?)?.toInt() ?? 5000).clamp(
    500,
    120000,
  );
  final intervalMs = (params['intervalMs'] as num?)?.toInt();
  final isolateId = params['isolateId'] as String?;

  Timer? timer;
  var fetching = false;
  var refetch = false;
  late final StreamController<Object?> controller;
  ValueListenable<CpuProfileData?>? dataNotifier;

  Future<void> fetch() async {
    if (fetching) {
      refetch = true;
      return;
    }
    fetching = true;
    try {
      final snapshot = switch (window) {
        _CpuWindow.live => await _fetchLiveSnapshot(
          lastMs: lastMs,
          isolateId: isolateId,
        ),
        _CpuWindow.recording => await _recordingSnapshot(),
      };
      if (snapshot != null && !controller.isClosed) {
        controller.add(project(snapshot));
      }
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

  void onChanged() => unawaited(fetch());

  controller = StreamController<Object?>(
    onListen: () {
      unawaited(fetch());
      switch (window) {
        case _CpuWindow.live:
          timer = Timer.periodic(
            Duration(milliseconds: math.max(1000, intervalMs ?? 2000)),
            (_) => unawaited(fetch()),
          );
        case _CpuWindow.recording:
          dataNotifier = _controller.cpuProfilerController.dataNotifier
            ..addListener(onChanged);
      }
    },
    onCancel: () {
      timer?.cancel();
      dataNotifier?.removeListener(onChanged);
    },
  );
  return controller.stream;
}

String? get _rootPackage =>
    serviceConnection.serviceManager.rootInfoNow().package;

Map<String, Schema> get _windowParams => {
  'window': S.string(
    description:
        '`live` (default): a rolling window of the most recent samples, '
        'refreshed every `intervalMs`; no recording needed. `recording`: '
        'the last profile recorded with cpu.startRecording/cpu.stopRecording '
        '(what the CPU Profiler screen shows); updates when a new recording '
        'is processed.',
    enumValues: ['live', 'recording'],
  ),
  'lastMs': S.integer(
    description: 'Live window length in milliseconds (default 5000).',
    minimum: 500,
    maximum: 120000,
  ),
  'intervalMs': S.integer(
    description: 'Live refresh interval in milliseconds (default 2000).',
    minimum: 1000,
  ),
  'isolateId': S.string(
    description:
        'Isolate to sample in `live` mode. Defaults to the selected isolate.',
  ),
  'userTag': S.string(
    description: 'Only include samples with this user tag (e.g. "Default").',
  ),
};

/// Data sources backed by the VM's CPU sampler and the CPU Profiler screen.
List<DataSourceDescriptor> cpuDataSources() => [
  DataSourceDescriptor(
    id: 'cpu.functions',
    description:
        'CPU usage per function (like the CPU Profiler "Method table"), '
        'aggregated from CPU samples of the connected app. One row per '
        'function, sorted by selfSamples descending. selfPct/totalPct are '
        'ratios (0..1) of all samples in the window; selfMs/totalMs are '
        'estimated from the sample period. `category` is one of app, '
        'flutter, dart, native, other. Not available for web apps.',
    paramsSchema: S.object(
      properties: {
        ..._windowParams,
        'includeNative': S.boolean(
          description:
              'Include native (VM/engine) frames (default true). When false '
              'their time is attributed to the nearest Dart caller.',
        ),
        'limit': S.integer(
          description: 'Maximum number of rows (default 200).',
          minimum: 1,
          maximum: 5000,
        ),
      },
    ),
    outputSchema: S.list(
      items: S.object(
        properties: {
          'name': S.string(),
          'package': S.string(
            description: 'Package name, `dart:<lib>`, or null (native).',
          ),
          'url': S.string(description: 'Library uri.'),
          'line': S.integer(),
          'category': S.string(enumValues: cpuCategories),
          'selfSamples': S.integer(),
          'totalSamples': S.integer(),
          'selfPct': S.number(),
          'totalPct': S.number(),
          'selfMs': S.number(),
          'totalMs': S.number(),
        },
      ),
    ),
    exampleExpressions: [
      '[:20]',
      "[?category=='app']",
      'sort_by(@, &totalSamples) | reverse(@) | [:10]',
      "[?package=='flutter'] | sum([].selfPct)",
    ],
    open: (context, params) {
      final includeNative = params['includeNative'] != false;
      final limit = (params['limit'] as num?)?.toInt() ?? 200;
      final userTag = params['userTag'] as String?;
      return _openCpuSource(
        params,
        (snapshot) => projectCpuFunctions(
          snapshot.data,
          userTag: userTag,
          includeNative: includeNative,
          rootPackage: _rootPackage,
          limit: limit,
        ),
      );
    },
  ),
  DataSourceDescriptor(
    id: 'cpu.activity',
    description:
        'CPU activity over time for the connected app: CPU samples bucketed '
        'by time. Each row has `timestamp` (bucket start, ms since epoch), '
        '`samples`, `cpuPct` (0..1, how busy the thread was), per-category '
        'sample counts by top-of-stack frame (app, flutter, dart, native, '
        'other), and `byUserTag` ({tag: samples}). Suitable for a '
        'TimeSeriesChart (e.g. series app/flutter/dart/native). Not '
        'available for web apps.',
    paramsSchema: S.object(
      properties: {
        ..._windowParams,
        'bucketMs': S.integer(
          description: 'Bucket size in milliseconds (default 250).',
          minimum: 50,
          maximum: 60000,
        ),
      },
    ),
    outputSchema: S.list(
      items: S.object(
        properties: {
          'timestamp': S.integer(),
          'samples': S.integer(),
          'cpuPct': S.number(),
          for (final category in cpuCategories) category: S.integer(),
          'byUserTag': S.object(),
        },
      ),
    ),
    exampleExpressions: [
      '[].{timestamp: timestamp, cpu: cpuPct}',
      'max_by(@, &samples)',
      'sum([].app)',
    ],
    open: (context, params) {
      final bucketMs = ((params['bucketMs'] as num?)?.toInt() ?? 250).clamp(
        50,
        60000,
      );
      final userTag = params['userTag'] as String?;
      return _openCpuSource(
        params,
        (snapshot) => projectCpuActivity(
          snapshot.data,
          bucketMs: bucketMs,
          epochOffsetMicros: snapshot.epochOffsetMicros,
          rootPackage: _rootPackage,
          userTag: userTag,
          startMicros: snapshot.startMicros,
          endMicros: snapshot.endMicros,
        ),
      );
    },
  ),
  DataSourceDescriptor(
    id: 'cpu.status',
    description:
        'State of the CPU Profiler: `{recording, busy, profilerEnabled, '
        'sampleCount}`. `busy` is one of none, fetching, processing. '
        '`sampleCount` is the number of samples in the last recording.',
    paramsSchema: S.object(),
    outputSchema: S.object(
      properties: {
        'recording': S.boolean(),
        'busy': S.string(enumValues: ['none', 'fetching', 'processing']),
        'profilerEnabled': S.boolean(),
        'sampleCount': S.integer(),
      },
    ),
    exampleExpressions: ["recording && 'Stop' || 'Record'"],
    open: (context, params) async* {
      final controller = _controller;
      await controller.initialized;
      final cpu = controller.cpuProfilerController;
      yield* streamFromListenables(
        [
          controller.recordingNotifier,
          cpu.profilerBusyStatus,
          cpu.dataNotifier,
          ?cpu.profilerFlagNotifier,
        ],
        () => {
          'recording': controller.recordingNotifier.value,
          'busy': cpu.profilerBusyStatus.value.name,
          'profilerEnabled': cpu.profilerEnabled,
          'sampleCount': cpu.dataNotifier.value?.cpuSamples.length ?? 0,
        },
      );
    },
  ),
];

/// Actions backed by the [ProfilerScreenController].
List<ActionDescriptor> cpuActions() => [
  ActionDescriptor(
    id: 'cpu.startRecording',
    description:
        'Starts recording a CPU profile (clears the previous recording and '
        'enables the VM CPU profiler if needed). Use `cpu.stopRecording` to '
        'finish; the result is available via window: "recording".',
    run: (context, args) async {
      await _checkedService();
      final controller = _controller;
      await controller.initialized;
      final cpu = controller.cpuProfilerController;
      if (!cpu.profilerEnabled) await cpu.enableCpuProfiler();
      if (cpu.profilerBusyStatus.value != CpuProfilerBusyStatus.none) {
        throw GenUiDataException('The CPU profiler is busy; try again.');
      }
      await controller.startRecording();
      return null;
    },
  ),
  ActionDescriptor(
    id: 'cpu.stopRecording',
    description:
        'Stops the current CPU recording and processes the profile. Does '
        'nothing if not recording.',
    run: (context, args) async {
      final controller = _controller;
      await controller.initialized;
      if (!controller.recordingNotifier.value) return null;
      await controller.stopRecording();
      return null;
    },
  ),
  ActionDescriptor(
    id: 'cpu.clear',
    description:
        'Clears the recorded CPU profile and the VM\'s CPU sample buffer '
        '(live windows will briefly be empty).',
    run: (context, args) async {
      final controller = _controller;
      await controller.initialized;
      if (controller.cpuProfilerController.profilerBusyStatus.value !=
          CpuProfilerBusyStatus.none) {
        throw GenUiDataException('The CPU profiler is busy; try again.');
      }
      await controller.clear();
      return null;
    },
  ),
];
