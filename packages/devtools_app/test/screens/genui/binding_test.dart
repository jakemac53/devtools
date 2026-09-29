// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'dart:async';

import 'package:devtools_app/src/screens/genui/catalog/action_delegate.dart';
import 'package:devtools_app/src/screens/genui/catalog/data_source_item.dart';
import 'package:devtools_app/src/screens/genui/data/actions.dart';
import 'package:devtools_app/src/screens/genui/data/data_source.dart';
import 'package:devtools_app/src/screens/genui/sources/default_registries.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:genui/genui.dart';
import 'package:json_schema_builder/json_schema_builder.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  late GenUiRegistries registries;
  late InMemoryDataModel dataModel;
  late DataContext dataContext;
  late List<Map<String, Object?>> openedWith;

  setUp(() {
    openedWith = [];
    registries = GenUiRegistries.empty();
    registries.dataSources.register(
      DataSourceDescriptor(
        id: 'test.numbers',
        description: 'Numbers up to `count`.',
        paramsSchema: S.object(properties: {'count': S.integer()}),
        outputSchema: S.list(items: S.integer()),
        open: (context, params) {
          openedWith.add(params);
          final count = (params['count'] as num?)?.toInt() ?? 3;
          return Stream.value([for (var i = 0; i < count; i++) i]);
        },
      ),
    );
    dataModel = InMemoryDataModel();
    dataContext = DataContext(dataModel, DataPath.root);
  });

  tearDown(() => dataModel.dispose());

  Widget binding(DataSourceConfig config, {List<Object>? errors}) {
    return MaterialApp(
      home: Scaffold(
        body: DataSourceBinding(
          registry: registries.dataSources,
          dataContext: dataContext,
          config: config,
          onError: (e, _) => errors?.add(e),
        ),
      ),
    );
  }

  group('DataSourceBinding', () {
    testWidgets('writes transformed values to targetPath', (tester) async {
      await tester.pumpWidget(
        binding(
          const DataSourceConfig(
            source: 'test.numbers',
            params: {'count': 4},
            expression: 'sum(@)',
            targetPath: '/total',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(dataModel.getValue<Object?>(DataPath('/total')), 6);
    });

    testWidgets('re-opens the source when a bound param changes', (
      tester,
    ) async {
      dataModel.update(DataPath('/count'), 2);
      await tester.pumpWidget(
        binding(
          const DataSourceConfig(
            source: 'test.numbers',
            params: {
              'count': {'path': '/count'},
            },
            targetPath: '/numbers',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(dataModel.getValue<Object?>(DataPath('/numbers')), [0, 1]);

      dataModel.update(DataPath('/count'), 3);
      await tester.pumpAndSettle();
      expect(dataModel.getValue<Object?>(DataPath('/numbers')), [0, 1, 2]);
      expect(openedWith, [
        {'count': 2},
        {'count': 3},
      ]);
    });

    testWidgets('reports errors once and shows them inline', (tester) async {
      final errors = <Object>[];
      await tester.pumpWidget(
        binding(
          const DataSourceConfig(
            source: 'test.missing',
            targetPath: '/x',
            errorPath: '/error',
          ),
          errors: errors,
        ),
      );
      await tester.pumpAndSettle();
      expect(errors, hasLength(1));
      expect(find.textContaining('Unknown data source'), findsOneWidget);
      expect(
        dataModel.getValue<Object?>(DataPath('/error')),
        contains('Unknown data source'),
      );
    });
  });

  group('DevToolsActionDelegate', () {
    late List<Map<String, Object?>> runs;
    late bool confirm;
    late DevToolsActionDelegate delegate;

    setUp(() {
      runs = [];
      confirm = true;
      final actions = ActionRegistry(refs: registries.refs)
        ..register(
          ActionDescriptor(
            id: 'test.safe',
            description: 'Safe.',
            run: (context, args) async {
              runs.add(args);
              return {'ok': true};
            },
          ),
        )
        ..register(
          ActionDescriptor(
            id: 'test.mutating',
            description: 'Mutates.',
            mutatesApp: true,
            run: (context, args) async {
              runs.add(args);
              return null;
            },
          ),
        );
      delegate = DevToolsActionDelegate(
        actions,
        confirm: (context, action) async => confirm,
      );
    });

    Future<bool> dispatch(
      WidgetTester tester,
      String name, [
      Map<String, Object?> context = const {},
    ]) async {
      late bool handled;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (buildContext) {
              handled = delegate.handleEvent(
                buildContext,
                UserActionEvent(
                  name: name,
                  sourceComponentId: 'button',
                  context: context,
                ),
                _FakeSurfaceContext(dataModel),
                (_, _, _, _) => const SizedBox(),
              );
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      return handled;
    }

    testWidgets('runs registered actions and writes results', (tester) async {
      final handled = await dispatch(tester, 'test.safe', {
        'a': 1,
        actionResultPathKey: '/result',
      });
      expect(handled, isTrue);
      expect(runs, [
        {'a': 1},
      ]);
      expect(dataModel.getValue<Object?>(DataPath('/result')), {'ok': true});
    });

    testWidgets('leaves unknown events to genui', (tester) async {
      expect(await dispatch(tester, 'somethingElse'), isFalse);
      expect(runs, isEmpty);
    });

    testWidgets('does not run mutating actions unless confirmed', (
      tester,
    ) async {
      confirm = false;
      expect(await dispatch(tester, 'test.mutating'), isTrue);
      expect(runs, isEmpty);

      confirm = true;
      await dispatch(tester, 'test.mutating');
      expect(runs, hasLength(1));
    });
  });
}

class _FakeSurfaceContext implements SurfaceContext {
  _FakeSurfaceContext(this.dataModel);

  @override
  final DataModel dataModel;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
