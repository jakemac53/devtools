// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'dart:convert';

import 'package:devtools_app/src/screens/genui/catalog/devtools_catalog.dart';
import 'package:devtools_app/src/screens/genui/genui_controller.dart';
import 'package:devtools_app/src/screens/genui/service/genui_vm_service.dart';
import 'package:devtools_app/src/screens/genui/sources/default_registries.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:genui/genui.dart';
import 'package:vm_service/vm_service.dart';

List<Map<String, Object?>> _messages({String component = 'Text'}) => [
  {
    'version': 'v0.9',
    'createSurface': {'surfaceId': 'main', 'catalogId': devToolsCatalogId},
  },
  {
    'version': 'v0.9',
    'updateComponents': {
      'surfaceId': 'main',
      'components': [
        {'id': 'root', 'component': component, 'text': 'Hello'},
      ],
    },
  },
];

class _FakeVmService extends Fake implements VmService {
  final callbacks = <String, ServiceCallback>{};
  final registered = <String, String>{};

  /// The namespace the VM service gives registered methods (e.g. `s2`).
  String namespace = 's2';

  @override
  void registerServiceCallback(String service, ServiceCallback cb) {
    callbacks[service] = cb;
  }

  @override
  Future<Success> registerService(String service, String alias) async {
    registered[service] = alias;
    return Success();
  }

  @override
  Future<Response> callMethod(
    String method, {
    String? isolateId,
    Map<String, dynamic>? args,
  }) async {
    final callback = callbacks[genUiServiceName];
    if (callback == null || method != '$namespace.$genUiServiceName') {
      throw RPCError(method, RPCErrorKind.kMethodNotFound.code, 'Not found');
    }
    final response = await callback({...?args});
    return Response.parse(response['result'] as Map<String, dynamic>)!;
  }
}

void main() {
  late GenUiController controller;
  late bool enabled;
  late int showScreenCount;
  late GenUiVmServiceHandler handler;

  setUp(() {
    controller = GenUiController(registries: GenUiRegistries.defaults())
      ..init();
    enabled = true;
    showScreenCount = 0;
    handler = GenUiVmServiceHandler(
      controller: () => controller,
      enabled: () => enabled,
      showGenUiScreen: () => showScreenCount++,
      renderSettleDuration: Duration.zero,
    );
  });

  tearDown(() => controller.dispose());

  Future<Object?> call(Map<String, dynamic> params) async {
    final response = await handler.call(params);
    expect(response, contains('result'), reason: '$response');
    // Must survive the VM service's JSON encoding.
    final result = jsonDecode(jsonEncode(response['result'])) as Map;
    return result['value'];
  }

  Future<String> callError(Map<String, dynamic> params) async {
    final response = await handler.call(params);
    expect(response, contains('error'), reason: '$response');
    return (response['error'] as Map)['message'] as String;
  }

  group('GenUiVmServiceHandler', () {
    test('reports when the experiment is disabled', () async {
      enabled = false;
      expect(
        await callError({'command': 'help'}),
        GenUiVmServiceHandler.experimentDisabledMessage,
      );
    });

    test('reports when not connected', () async {
      handler = GenUiVmServiceHandler(
        controller: () => null,
        enabled: () => true,
      );
      expect(
        await callError({'command': 'help'}),
        GenUiVmServiceHandler.notConnectedMessage,
      );
    });

    test('rejects missing and unknown commands', () async {
      expect(await callError({}), contains('Missing `command`'));
      expect(
        await callError({'command': 'nope'}),
        contains('Unknown command: nope'),
      );
    });

    test('help lists commands and agent tools', () async {
      final help = await call({'command': 'help'}) as Map;
      final commands = help['commands'] as Map;
      expect(
        commands.keys,
        containsAll([
          'help',
          'getInstructions',
          'render',
          'pollEvents',
          for (final tool in controller.agentTools) tool.name,
        ]),
      );
    });

    test('getInstructions targets external agents', () async {
      final result = await call({'command': 'getInstructions'}) as Map;
      final instructions = result['instructions'] as String;
      expect(instructions, contains('`render` command'));
      expect(instructions, contains(devToolsCatalogId));
    });

    test('passes other commands to the agent tools', () async {
      final sources = await call({'command': 'listDataSources'}) as List;
      expect(sources, isNotEmpty);
      final description =
          await call({
                'command': 'describeDataSource',
                'id': (sources.first as Map)['id'],
              })
              as Map;
      expect(description, contains('outputSchema'));
    });

    test('render applies messages, shows the screen and exports', () async {
      final result =
          await call({'command': 'render', 'messages': _messages()}) as Map;
      expect(result['applied'], 2);
      expect(result['surfaceIds'], ['main']);
      expect(result, isNot(contains('errors')));
      expect(showScreenCount, 1);

      final exported = await call({'command': 'exportSpec'}) as Map;
      expect((exported['spec'] as Map)['messages'], hasLength(2));

      await call({'command': 'clear'});
      expect(controller.surfaceController.activeSurfaceIds, isEmpty);
    });

    test('render accepts stringified messages', () async {
      final result =
          await call({'command': 'render', 'messages': jsonEncode(_messages())})
              as Map;
      expect(result['surfaceIds'], ['main']);
    });

    test('render returns validation errors', () async {
      final result =
          await call({
                'command': 'render',
                'messages': _messages(component: 'NotAComponent'),
              })
              as Map;
      expect(result['errors'], isNotEmpty);
      // Render errors are not reported again as events.
      expect(await call({'command': 'pollEvents'}), {'events': <Object?>[]});
    });

    test('pollEvents returns and clears user interactions', () async {
      controller.surfaceController.handleUiEvent(
        UserActionEvent(
          name: 'refresh',
          sourceComponentId: 'button',
          surfaceId: 'main',
        ),
      );
      await pumpEventQueue();
      final result = await call({'command': 'pollEvents'}) as Map;
      final events = result['events'] as List;
      expect(events, hasLength(1));
      expect(((events.single as Map)['action'] as Map)['name'], 'refresh');
      expect(await call({'command': 'pollEvents'}), {'events': <Object?>[]});
    });
  });

  group('GenUiVmServiceRegistrar', () {
    test('registers once per connection while enabled', () async {
      final enabledNotifier = ValueNotifier(false);
      final connection = ValueNotifier(0);
      VmService? service;
      final registrar = GenUiVmServiceRegistrar(
        enabled: enabledNotifier,
        connection: connection,
        currentService: () => service,
        handler: handler,
      );
      addTearDown(registrar.dispose);

      final first = _FakeVmService();
      service = first;
      connection.value++;
      await pumpEventQueue();
      expect(first.registered, isEmpty, reason: 'experiment disabled');

      enabledNotifier.value = true;
      await pumpEventQueue();
      expect(first.registered, {genUiServiceName: genUiServiceAlias});
      expect(first.callbacks.keys, [genUiServiceName]);

      final second = _FakeVmService();
      service = second;
      connection.value++;
      await pumpEventQueue();
      expect(second.registered, {genUiServiceName: genUiServiceAlias});
      expect(registrar.registeredService, same(second));
    });

    test('reports its namespaced method name once registered', () async {
      final service = _FakeVmService()..namespace = 's3';
      final reported = <String>[];
      final registrar = GenUiVmServiceRegistrar(
        enabled: ValueNotifier(true),
        connection: ValueNotifier(0),
        currentService: () => service,
        handler: handler,
        onRegistered: reported.add,
      );
      addTearDown(registrar.dispose);
      await pumpEventQueue();
      expect(reported, ['s3.$genUiServiceName']);

      // Other commands still reach the handler.
      final response = await service.callbacks[genUiServiceName]!({
        'command': 'pollEvents',
      });
      expect(response['result'], {
        'value': {'events': <Object?>[]},
      });
    });
  });
}
