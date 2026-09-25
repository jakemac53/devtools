// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'package:json_schema_builder/json_schema_builder.dart';

import '../../../shared/globals.dart';
import '../../../shared/http/http_request_data.dart';
import '../../network/network_controller.dart';
import '../../network/network_model.dart';
import '../data/actions.dart';
import '../data/data_source.dart';
import '../data/json_utils.dart';
import '../data/ref_store.dart';

/// The `_ref` kind used for [NetworkRequest]s.
const networkRequestRefKind = 'network.request';

NetworkController get _controller =>
    screenControllers.lookup<NetworkController>();

/// Projects a [NetworkRequest] into a JSON row.
///
/// This is the single place that decides how network requests look to
/// generated UI; the Network screen's own table columns read the same model
/// fields.
JsonObject projectNetworkRequest(NetworkRequest request, GenUiRefStore refs) {
  return {
    refKey: refs.refFor(request, kind: networkRequestRefKind, id: request.id),
    'id': request.id,
    'method': request.method,
    'uri': request.uri,
    'status': request.status,
    'type': request.type,
    'contentType': request.contentType,
    'durationMs': request.duration == null
        ? null
        : request.duration!.inMicroseconds / 1000,
    'startTime': request.startTimestamp?.millisecondsSinceEpoch,
    'endTime': request.endTimestamp?.millisecondsSinceEpoch,
    'port': request.port,
    'didFail': request.didFail,
    'inProgress': request.inProgress,
    'isHttp': request is DartIOHttpRequestData,
    if (request is DartIOHttpRequestData) ...{
      'requestBytes': request.requestBody?.length,
      'responseBytes': request.responseBody?.length,
    },
    if (request is Socket) ...{
      'readBytes': request.readBytes,
      'writeBytes': request.writeBytes,
    },
  };
}

final _networkRequestRowSchema = S.object(
  description: 'A network request (HTTP request or socket).',
  properties: {
    refKey: S.string(
      description:
          'Opaque handle to the request. Pass the whole row (or this value) '
          'to NetworkRequestDetails.',
    ),
    'id': S.string(),
    'method': S.string(description: 'HTTP method, or SOCKET for sockets.'),
    'uri': S.string(),
    'status': S.string(description: 'HTTP status code, or Open/Closed.'),
    'type': S.string(description: 'e.g. json, html, tcp.'),
    'contentType': S.string(),
    'durationMs': S.number(),
    'startTime': S.integer(description: 'Milliseconds since epoch.'),
    'endTime': S.integer(description: 'Milliseconds since epoch.'),
    'port': S.integer(),
    'didFail': S.boolean(),
    'inProgress': S.boolean(),
    'isHttp': S.boolean(),
    'requestBytes': S.integer(),
    'responseBytes': S.integer(),
    'readBytes': S.integer(description: 'Sockets only.'),
    'writeBytes': S.integer(description: 'Sockets only.'),
  },
);

/// Data sources backed by the [NetworkController].
List<DataSourceDescriptor> networkDataSources() => [
  DataSourceDescriptor(
    id: 'network.requests',
    description:
        'Live list of network requests (HTTP requests and sockets) made by '
        'the connected app while network recording is enabled. Shares state '
        'with the Network screen.',
    paramsSchema: S.object(properties: {}),
    outputSchema: S.list(items: _networkRequestRowSchema),
    exampleExpressions: [
      "[?method == 'GET']",
      'sort_by(@, &durationMs)[-10:]',
      '[?didFail]',
      '[].{uri: uri, status: status, ms: durationMs, _ref: _ref}',
    ],
    open: (context, params) => streamFromListenable(
      _controller.requests,
      (requests) => [
        for (final r in requests) projectNetworkRequest(r, context.refs),
      ],
    ),
  ),
  DataSourceDescriptor(
    id: 'network.recording',
    description: 'Whether network recording is currently enabled.',
    paramsSchema: S.object(properties: {}),
    outputSchema: S.object(properties: {'recording': S.boolean()}),
    open: (context, params) => streamFromListenable(
      _controller.recordingNotifier,
      (recording) => {'recording': recording},
    ),
  ),
];

/// Actions backed by the [NetworkController].
List<ActionDescriptor> networkActions() => [
  ActionDescriptor(
    id: 'network.startRecording',
    description: 'Starts recording network traffic.',
    run: (context, args) async {
      await _controller.startRecording();
      return {'recording': true};
    },
  ),
  ActionDescriptor(
    id: 'network.stopRecording',
    description: 'Stops recording network traffic.',
    run: (context, args) async {
      await _controller.stopRecording();
      return {'recording': false};
    },
  ),
  ActionDescriptor(
    id: 'network.toggleRecording',
    description: 'Toggles network recording on or off.',
    run: (context, args) async {
      final recording = !_controller.recordingNotifier.value;
      await _controller.togglePolling(recording);
      return {'recording': recording};
    },
  ),
  ActionDescriptor(
    id: 'network.clear',
    description: 'Clears all recorded network requests.',
    run: (context, args) async {
      await _controller.clear();
      return null;
    },
  ),
];
