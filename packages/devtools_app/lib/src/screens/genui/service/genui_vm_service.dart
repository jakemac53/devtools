// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:collection/collection.dart';
import 'package:devtools_app_shared/utils.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:vm_service/vm_service.dart';

import '../agent/agent_tools.dart';
import '../agent/system_prompt.dart';
import '../data/json_utils.dart';
import '../genui_controller.dart';
import '../genui_spec.dart';

final _log = Logger('genui_vm_service');

/// The name of the VM service method that DevTools registers so external
/// agents can drive GenUI.
///
/// Registered services are namespaced by the VM service (DDS) per client, so
/// callers invoke it as `<namespace>.genUi` (e.g. `s0.genUi`); the full name
/// is announced in the `ServiceRegistered` event on the `Service` stream.
const genUiServiceName = 'genUi';

/// The human readable alias for [genUiServiceName].
const genUiServiceAlias = 'DevTools GenUI';

/// Handles calls to the [genUiServiceName] VM service method.
///
/// This lets an agent outside of DevTools (e.g. a coding agent that talks to
/// the running app through the Dart MCP server's `vm_service` tool) answer
/// questions with live DevTools data and render custom DevTools UI, using the
/// same tools as the agent embedded in the GenUI screen (see
/// [buildGenUiAgentTools]).
///
/// Every call takes a `command` param; the other params depend on the
/// command. Use the `help` command for the list.
class GenUiVmServiceHandler {
  GenUiVmServiceHandler({
    required this.controller,
    required this.enabled,
    this.showGenUiScreen,
    this.renderSettleDuration = const Duration(milliseconds: 100),
  });

  /// Returns the current [GenUiController], or null when it is unavailable
  /// (e.g. DevTools is not connected to an app).
  final GenUiController? Function() controller;

  /// Whether the GenUI experiment is enabled.
  final bool Function() enabled;

  /// Navigates DevTools to the GenUI screen, so the user sees rendered UI.
  final VoidCallback? showGenUiScreen;

  /// How long `render` waits for asynchronous validation errors.
  final Duration renderSettleDuration;

  /// Message returned when the GenUI experiment is disabled.
  static const experimentDisabledMessage =
      'The GenUI experiment is disabled in DevTools. Ask the user to enable '
      'it in DevTools: Settings (gear icon) > Experimental features > '
      '"Enable GenUI".';

  /// Message returned when there is no [GenUiController].
  static const notConnectedMessage =
      'DevTools is not connected to this app. Ask the user to connect DevTools '
      'to the app (e.g. open DevTools from their IDE, or paste the VM service '
      'URI into the DevTools connect dialog).';

  /// The commands handled here in addition to the agent tools, with their
  /// descriptions.
  static const _commands = <String, String>{
    'help': 'Describes the available commands.',
    'getInstructions':
        'Returns the full instructions for building UI: the A2UI protocol, '
        'the component catalog schema and DevTools component guidance. Read '
        'them once before using `render`.',
    'render':
        'Applies A2UI messages to the GenUI page and shows it. Params: '
        '`messages` (a JSON list of A2UI messages, or a spec from '
        '`exportSpec`). Returns validation `errors`, if any.',
    'clear': 'Removes all surfaces from the GenUI page.',
    'exportSpec':
        'Returns the current surfaces as a replayable spec that `render` '
        'accepts.',
    'pollEvents':
        'Returns and clears the user interactions with the rendered UI '
        '(e.g. button presses with an `event` action) since the last call. '
        'DevTools actions (`action` with an `id`) run locally and are not '
        'reported.',
  };

  /// Handles a call to the VM service method.
  ///
  /// Returns a JSON-RPC response map: `{'result': ...}` or `{'error': ...}`.
  Future<Map<String, dynamic>> call(Map<String, dynamic> params) async {
    try {
      return {
        'result': {'value': toJsonSafe(await _handle(params))},
      };
    } on _GenUiServiceException catch (e) {
      return _error(e.message);
    } catch (e) {
      return _error('$e');
    }
  }

  static Map<String, dynamic> _error(String message) => {
    'error': {
      'code': RPCErrorKind.kServerError.code,
      'message': message,
      'data': {'details': message},
    },
  };

  Future<Object?> _handle(Map<String, dynamic> params) async {
    if (!enabled()) throw _GenUiServiceException(experimentDisabledMessage);
    final controller = this.controller();
    if (controller == null) throw _GenUiServiceException(notConnectedMessage);

    final input = _normalize(params);
    final command = input.remove('command');
    if (command is! String || command.isEmpty) {
      throw _GenUiServiceException(
        'Missing `command` param. Call with `command: help` for the list.',
      );
    }
    switch (command) {
      case 'help':
        return _help(controller);
      case 'getInstructions':
        return {
          'instructions': buildGenUiSystemPrompt(
            controller.catalog,
            external: true,
          ),
        };
      case 'render':
        final messages = parseSpecJson(input['messages'] ?? input['spec']);
        final errors = await controller.applyMessages(
          messages,
          settle: renderSettleDuration,
        );
        showGenUiScreen?.call();
        return {
          'applied': messages.length,
          'surfaceIds': controller.surfaceController.activeSurfaceIds.toList(),
          if (errors.isNotEmpty) 'errors': errors,
        };
      case 'clear':
        controller.clearSurfaces();
        return {'cleared': true};
      case 'exportSpec':
        return {'spec': jsonDecode(controller.exportSpec())};
      case 'pollEvents':
        return {'events': controller.takeExternalEvents()};
    }
    final tool = controller.agentTools.firstWhereOrNull(
      (t) => t.name == command,
    );
    if (tool == null) {
      throw _GenUiServiceException(
        'Unknown command: $command. Call with `command: help` for the list.',
      );
    }
    return tool.call(input);
  }

  JsonObject _help(GenUiController controller) => {
    'description':
        'DevTools GenUI shows custom, interactive debugging UI in the '
        "user's DevTools window, built from real DevTools components bound "
        'to live data from their running app. You can also query that live '
        'data directly to answer questions.',
    'workflow': '''
1. Discover data with listDataSources, describeDataSource and previewDataSource.
2. Answer questions about the app with queryDataSource (no UI needed).
3. To build UI, read getInstructions once, then send A2UI messages with render.
   Fix any returned errors and render again.
4. Use getSurfaceState to see the UI and what the user selected, and
   pollEvents to receive interactions with your UI.''',
    'commands': {
      for (final entry in _commands.entries)
        entry.key: {'description': entry.value},
      for (final tool in controller.agentTools)
        tool.name: {
          'description': tool.description,
          'params': tool.inputJsonSchema['properties'],
        },
    },
  };

  /// Copies [params], decoding values that may have been stringified by the
  /// caller (VM service params are often passed as strings).
  static JsonObject _normalize(Map<String, dynamic> params) {
    final input = <String, Object?>{...params};
    for (final key in const ['params', 'messages', 'spec']) {
      final value = input[key];
      if (value is String) {
        try {
          input[key] = jsonDecode(value);
        } on FormatException {
          throw _GenUiServiceException('`$key` is not valid JSON.');
        }
      }
    }
    for (final key in const ['offset', 'limit']) {
      final value = input[key];
      if (value is String) input[key] = int.tryParse(value) ?? value;
    }
    return input;
  }
}

class _GenUiServiceException implements Exception {
  _GenUiServiceException(this.message);

  final String message;
}

/// Registers [genUiServiceName] with the connected app's VM service while
/// the GenUI experiment is enabled.
///
/// Registration is tied to a VM service connection, so it is repeated for
/// every new connection. The VM service has no way to unregister a service,
/// so when the experiment is disabled the service stays registered and
/// [GenUiVmServiceHandler] reports that the experiment is disabled.
///
/// After registering, this finds the full, namespaced method name (e.g.
/// `s1.genUi`) and reports it to [onRegistered], so an embedder can tell an
/// external agent which method to call.
class GenUiVmServiceRegistrar extends DisposableController
    with AutoDisposeControllerMixin {
  GenUiVmServiceRegistrar({
    required this.enabled,
    required Listenable connection,
    required this.currentService,
    required this.handler,
    this.onRegistered,
  }) {
    addAutoDisposeListener(enabled, _update);
    addAutoDisposeListener(connection, _update);
    _update();
  }

  /// Whether the GenUI experiment is enabled.
  final ValueListenable<bool> enabled;

  /// Returns the VM service of the connected app, or null when disconnected.
  final VmService? Function() currentService;

  /// Handles calls to the registered service.
  final GenUiVmServiceHandler handler;

  /// Called with the full method name once it is registered and found.
  final void Function(String method)? onRegistered;

  /// The highest service namespace number (`s<n>`) tried when finding the
  /// registered method name.
  ///
  /// The VM service reuses freed numbers, so they stay small in practice.
  @visibleForTesting
  static const maxNamespace = 64;

  /// The command this registrar answers (before [handler]) to find its own
  /// method name; see [_findMethodName].
  static const _identifyCommand = '_identify';

  /// Identifies this DevTools instance to [_findMethodName], since every
  /// DevTools connected to the app registers a `genUi` method.
  final _instanceId = _randomId();

  static String _randomId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  /// The VM service the method is registered with, if any.
  @visibleForTesting
  VmService? get registeredService => _registeredService;
  VmService? _registeredService;

  void _update() {
    final service = currentService();
    if (!enabled.value || service == null) return;
    if (identical(service, _registeredService)) return;
    _registeredService = service;
    unawaited(_register(service));
  }

  Future<void> _register(VmService service) async {
    try {
      service.registerServiceCallback(genUiServiceName, _call);
      await service.registerService(genUiServiceName, genUiServiceAlias);
    } catch (e, st) {
      _log.warning('Failed to register the $genUiServiceName service', e, st);
      return;
    }
    final onRegistered = this.onRegistered;
    if (onRegistered == null) return;
    final method = await _findMethodName(service);
    if (method != null && identical(service, _registeredService)) {
      onRegistered(method);
    }
  }

  Future<Map<String, dynamic>> _call(Map<String, dynamic> params) async {
    if (params['command'] == _identifyCommand) {
      return {
        'result': {'type': 'Success', 'instanceId': _instanceId},
      };
    }
    return handler.call(params);
  }

  /// Returns the namespaced name of the method this registrar registered with
  /// [service], or null if it can't be found.
  ///
  /// The VM service only announces a registration to the other clients, so
  /// this calls `s<n>.genUi` for increasing `n` until this instance answers.
  Future<String?> _findMethodName(VmService service) async {
    for (var namespace = 0; namespace <= maxNamespace; namespace++) {
      final method = 's$namespace.$genUiServiceName';
      try {
        final response = await service.callMethod(
          method,
          args: {'command': _identifyCommand},
        );
        if (response.json?['instanceId'] == _instanceId) return method;
      } catch (_) {
        // No such method, or another client's method; try the next one.
      }
    }
    _log.warning('Could not find the registered $genUiServiceName method');
    return null;
  }
}
