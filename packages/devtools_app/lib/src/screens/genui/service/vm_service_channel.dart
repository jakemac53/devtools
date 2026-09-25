// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'dart:async';

import '../../../service/vm_service_wrapper.dart';
import '../../../shared/globals.dart';

/// A bidirectional JSON-RPC message channel to a VM service.
///
/// GenUI data sources reuse the regular DevTools screen controllers, which
/// talk to the VM service through `serviceConnection`. To run the GenUI screen
/// in environments where DevTools cannot open a WebSocket to the VM service
/// directly (for example when hosted as an MCP App inside a sandboxed iframe),
/// only the *transport* underneath the [VmServiceWrapper] needs to change -
/// the controllers and data sources stay the same.
///
/// Implementations might include:
/// - a WebSocket channel (what DevTools uses today via `FrameworkCore`), or
/// - a tunnel that forwards JSON-RPC messages through MCP tool calls to the
///   Dart MCP server, which owns the real VM service connection (not yet
///   implemented; see the feasibility report).
abstract interface class VmServiceMessageChannel {
  /// Incoming JSON-RPC messages (responses and stream events), as `String`s
  /// or UTF-8 encoded `List<int>`s.
  Stream<Object?> get incoming;

  /// Sends an outgoing JSON-RPC message.
  void send(String message);

  /// Completes when the channel is closed.
  Future<void> get done;

  /// Closes the channel.
  Future<void> close();
}

/// Connects DevTools' global `serviceConnection` to a VM service over
/// [channel].
///
/// This is the seam that makes the VM service transport pluggable: every
/// screen controller - and therefore every GenUI data source - works
/// unchanged on top of whichever channel is provided here.
Future<VmServiceWrapper> connectVmServiceOverChannel(
  VmServiceMessageChannel channel, {
  String? debugUri,
}) async {
  final service = VmServiceWrapper.defaultFactory(
    inStream: channel.incoming,
    writeMessage: channel.send,
    disposeHandler: channel.close,
    streamClosed: channel.done,
    wsUri: debugUri,
  );
  await serviceConnection.serviceManager.vmServiceOpened(
    service,
    onClosed: channel.done,
  );
  return service;
}
