// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'dart:async';

import 'package:devtools_app/src/screens/genui/agent/agent_tools.dart';
import 'package:devtools_app/src/screens/genui/data/actions.dart';
import 'package:devtools_app/src/screens/genui/data/data_source.dart';
import 'package:devtools_app/src/screens/genui/data/json_utils.dart';
import 'package:devtools_app/src/screens/genui/data/ref_store.dart';
import 'package:devtools_app/src/screens/genui/sources/default_registries.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:json_schema_builder/json_schema_builder.dart';

class _Item {
  _Item(this.id, this.ms);
  final String id;
  final int ms;
}

void main() {
  late GenUiRegistries registries;
  late ValueNotifier<List<_Item>> items;

  setUp(() {
    items = ValueNotifier([_Item('a', 30), _Item('b', 10), _Item('c', 20)]);
    registries = GenUiRegistries.empty();
    registries.dataSources.register(
      DataSourceDescriptor(
        id: 'test.items',
        description: 'Test items.',
        paramsSchema: S.object(properties: {'min': S.integer()}),
        outputSchema: S.list(items: S.object()),
        open: (context, params) => streamFromListenable(
          items,
          (list) => [
            for (final item in list)
              if (item.ms >= ((params['min'] as num?) ?? 0))
                {
                  refKey: context.refs.refFor(item, kind: 'item', id: item.id),
                  'id': item.id,
                  'ms': item.ms,
                },
          ],
          throttle: Duration.zero,
        ),
      ),
    );
    registries.actions.register(
      ActionDescriptor(
        id: 'test.add',
        description: 'Adds an item.',
        run: (context, args) async {
          items.value = [
            ...items.value,
            _Item(args['id'] as String, args['ms'] as int),
          ];
          return {'count': items.value.length, 'at': DateTime(2020)};
        },
      ),
    );
  });

  group('DataSourceRegistry', () {
    test('query emits projected values', () async {
      final value = await registries.dataSources.query('test.items').first;
      expect(value, hasLength(3));
      expect((value as List).first, containsPair('id', 'a'));
    });

    test('query applies params and JMESPath expressions', () async {
      final value = await registries.dataSources
          .query(
            'test.items',
            params: {'min': 15},
            expression: 'sort_by(@, &ms)[].id',
          )
          .first;
      expect(value, ['c', 'a']);
    });

    test('query re-emits when the underlying listenable changes', () async {
      final values = <Object?>[];
      final sub = registries.dataSources
          .query('test.items', expression: 'length(@)')
          .listen(values.add);
      await pumpEventQueue();
      items.value = [...items.value, _Item('d', 1)];
      await pumpEventQueue();
      await sub.cancel();
      expect(values, [3, 4]);
    });

    test('unknown sources and bad expressions produce stream errors', () {
      expect(
        registries.dataSources.query('nope').first,
        throwsA(isA<GenUiDataException>()),
      );
      expect(
        registries.dataSources.query('test.items', expression: '[?').first,
        throwsA(isA<GenUiDataException>()),
      );
    });

    test('preview truncates long lists', () async {
      final preview = await registries.dataSources.preview(
        'test.items',
        limit: 2,
      );
      expect(preview, isA<Map>());
      expect((preview as Map)['totalLength'], 3);
      expect(preview['items'], hasLength(2));
    });

    test('_ref values resolve back to the typed object', () async {
      final rows = await registries.dataSources.query('test.items').first;
      final first = (rows as List).first as JsonObject;
      final resolved = registries.refs.resolve<_Item>(first);
      expect(resolved, same(items.value.first));
      expect(registries.refs.resolve<_Item>(first[refKey]), same(resolved));
      expect(registries.refs.resolve<String>(first), isNull);
      expect(registries.refs.resolve<_Item>('item:missing'), isNull);
    });
  });

  group('streamFromListenable', () {
    test('throttles bursts of notifications', () {
      fakeAsync((async) {
        final notifier = ValueNotifier(0);
        final values = <Object?>[];
        final sub = streamFromListenable(
          notifier,
          (v) => v,
          throttle: const Duration(milliseconds: 100),
        ).listen(values.add);
        async.flushMicrotasks();
        for (var i = 1; i <= 5; i++) {
          notifier.value = i;
        }
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 150));
        unawaited(sub.cancel());
        // Initial value, the first change, then one trailing emission.
        expect(values, [0, 1, 5]);
      });
    });
  });

  group('ActionRegistry', () {
    test('runs actions and returns JSON-safe results', () async {
      final result = await registries.actions.run(
        'test.add',
        args: {'id': 'd', 'ms': 5},
      );
      expect(items.value, hasLength(4));
      expect(result, {'count': 4, 'at': DateTime(2020).millisecondsSinceEpoch});
    });

    test('throws for unknown actions', () {
      expect(
        registries.actions.run('nope'),
        throwsA(isA<GenUiDataException>()),
      );
    });
  });

  group('agent tools', () {
    late Map<String, GenUiAgentTool> tools;

    setUp(() {
      tools = {
        for (final tool in buildGenUiAgentTools(
          registries,
          surfaceState: (id) => {'surface': id, 'list': List.filled(20, 1)},
        ))
          tool.name: tool,
      };
    });

    test('expose the expected tool names', () {
      expect(tools.keys, [
        'listDataSources',
        'describeDataSource',
        'previewDataSource',
        'queryDataSource',
        'listActions',
        'describeAction',
        'getSurfaceState',
      ]);
    });

    test('listDataSources and describeDataSource', () async {
      expect(await tools['listDataSources']!.call({}), [
        {'id': 'test.items', 'description': 'Test items.'},
      ]);
      final description =
          await tools['describeDataSource']!.call({'id': 'test.items'}) as Map;
      expect(description['paramsSchema'], isA<Map>());
    });

    test('previewDataSource applies expressions', () async {
      expect(
        await tools['previewDataSource']!.call({
          'id': 'test.items',
          'expression': '[0].id',
        }),
        {'value': 'a'},
      );
    });

    test('queryDataSource returns full aggregated values', () async {
      expect(
        await tools['queryDataSource']!.call({
          'id': 'test.items',
          'params': {'min': 15},
          'expression': 'sum([].ms)',
        }),
        {'value': 50},
      );
      // Unlike previewDataSource, lists are not truncated to 5 by default.
      items.value = [for (var i = 0; i < 20; i++) _Item('$i', i)];
      expect(
        await tools['queryDataSource']!.call({
          'id': 'test.items',
          'expression': '[].id',
        }),
        {'items': hasLength(20), 'offset': 0, 'totalLength': 20},
      );
    });

    test('queryDataSource paginates with offsets over live data', () async {
      final query = tools['queryDataSource']!;
      final args = {'id': 'test.items', 'expression': '[].id', 'limit': 2};
      final first = await query(args) as Map;
      expect(first, {
        'items': ['a', 'b'],
        'offset': 0,
        'totalLength': 3,
        'nextOffset': 2,
      });
      expect(await query({...args, 'offset': first['nextOffset']}), {
        'items': ['c'],
        'offset': 2,
        'totalLength': 3,
      });
      // Every page re-queries the live data.
      items.value = [...items.value, _Item('d', 1)];
      expect(await query({...args, 'offset': 2}), {
        'items': ['c', 'd'],
        'offset': 2,
        'totalLength': 4,
      });
      expect(await query({...args, 'offset': 10}), {
        'items': isEmpty,
        'offset': 10,
        'totalLength': 4,
      });
      expect(await query({...args, 'offset': -1}), {
        'error': contains('`offset`'),
      });
    });

    test('queryDataSource reports bad expressions', () async {
      expect(
        await tools['queryDataSource']!.call({
          'id': 'test.items',
          'expression': '[?',
        }),
        {'error': contains('Invalid JMESPath')},
      );
    });

    test('actions tools', () async {
      expect(await tools['listActions']!.call({}), [
        {'id': 'test.add', 'description': 'Adds an item.', 'mutatesApp': false},
      ]);
      final description =
          await tools['describeAction']!.call({'id': 'test.add'}) as Map;
      expect(description['argsSchema'], isA<Map>());
    });

    test('getSurfaceState truncates data', () async {
      final state =
          await tools['getSurfaceState']!.call({'surfaceId': 'main'}) as Map;
      expect(state['surface'], 'main');
      expect((state['list'] as Map)['truncated'], isTrue);
    });

    test('errors are returned to the agent instead of thrown', () async {
      expect(await tools['describeDataSource']!.call({'id': 'nope'}), {
        'error': contains('Unknown data source'),
      });
      expect(await tools['describeAction']!.call({}), {
        'error': contains('`id`'),
      });
    });
  });

  group('json utils', () {
    test('toJsonSafe', () {
      expect(
        toJsonSafe({
          1: const Duration(milliseconds: 1),
          'b': [double.nan, TargetPlatform.android, _Item('x', 1)],
        }),
        {
          '1': 1000,
          'b': ['NaN', 'android', isA<String>()],
        },
      );
    });

    test('truncateForPreview', () {
      expect(
        truncateForPreview(
          {
            'list': [1, 2, 3],
            's': 'x' * 10,
          },
          maxListLength: 2,
          maxStringLength: 4,
        ),
        {
          'list': {
            'items': [1, 2],
            'totalLength': 3,
            'truncated': true,
          },
          's': 'xxxx…',
        },
      );
    });
  });
}
