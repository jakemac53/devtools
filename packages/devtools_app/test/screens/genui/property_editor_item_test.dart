// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'dart:async';

import 'package:devtools_app/src/screens/genui/catalog/property_editor_item.dart';
import 'package:devtools_app/src/shared/diagnostics/diagnostics_node.dart';
import 'package:devtools_app/src/shared/editor/api_classes.dart';
import 'package:devtools_app/src/shared/editor/editor_client.dart';
import 'package:devtools_app/src/standalone_ui/ide_shared/property_editor/property_editor_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

RemoteDiagnosticsNode _node({
  bool local = true,
  Object? file = 'file:///app/lib/main.dart',
  int line = 10,
  int column = 5,
}) => RemoteDiagnosticsNode(
  {
    'description': 'Text',
    'widgetRuntimeType': 'Text',
    'valueId': 'id',
    'createdByLocalProject': local,
    'creationLocation': {'file': ?file, 'line': line, 'column': column},
  },
  null,
  false,
  null,
);

EditableArgumentsResult _result(String name) => EditableArgumentsResult(
  name: name,
  args: [
    EditableArgument(
      name: 'data',
      type: 'string',
      hasArgument: true,
      hasDefault: false,
      isNullable: false,
      isRequired: true,
      isEditable: true,
      isDeprecated: false,
      value: 'hi',
    ),
  ],
);

class _FakeEditorClient extends Fake implements EditorClient {
  final events = StreamController<ActiveLocationChangedEvent>();

  /// Pending `getEditableArguments` requests, by position.
  final pending = <CursorPosition, Completer<EditableArgumentsResult?>>{};

  final edits = <(TextDocument, CursorPosition, String, Object?)>[];

  @override
  final editableArgumentsApiIsRegistered = ValueNotifier(true);

  @override
  Stream<ActiveLocationChangedEvent> get activeLocationChangedStream =>
      events.stream;

  @override
  Future<EditableArgumentsResult?> getEditableArguments({
    required TextDocument textDocument,
    required CursorPosition position,
    required String screenId,
  }) => (pending[position] = Completer()).future;

  @override
  Future<CodeActionResult?> getRefactors({
    required TextDocument textDocument,
    required EditorRange range,
    required String screenId,
  }) async => null;

  @override
  Future<GenericApiResponse> editArgument<T>({
    required TextDocument textDocument,
    required CursorPosition position,
    required String name,
    required T value,
    required String screenId,
  }) async {
    edits.add((textDocument, position, name, value));
    return GenericApiResponse(success: true);
  }
}

void main() {
  group('propertyEditorTargetFor', () {
    test('maps 1-based creation locations to 0-based positions', () {
      final target = propertyEditorTargetFor(_node())!;
      expect(target.fileUri, 'file:///app/lib/main.dart');
      expect(target.position, CursorPosition(line: 9, character: 4));
    });

    test('converts absolute paths to file URIs', () {
      final target = propertyEditorTargetFor(_node(file: '/app/lib/a.dart'))!;
      expect(target.fileUri, 'file:///app/lib/a.dart');
    });

    test('rejects widgets that have no editable source', () {
      expect(propertyEditorTargetFor(null), isNull);
      expect(propertyEditorTargetFor(_node(local: false)), isNull);
      expect(propertyEditorTargetFor(_node(file: null)), isNull);
      expect(propertyEditorTargetFor(_node(line: 0)), isNull);
      expect(
        propertyEditorTargetFor(_node(file: 'org-dartlang-app:///main.dart')),
        isNull,
      );
    });
  });

  group('PropertyEditorController with followActiveLocation: false', () {
    late _FakeEditorClient editor;
    late PropertyEditorController controller;
    final doc = TextDocument(uriAsString: 'file:///a.dart', version: null);
    final pos1 = CursorPosition(line: 1, character: 2);
    final pos2 = CursorPosition(line: 5, character: 2);

    setUp(() {
      editor = _FakeEditorClient();
      controller = PropertyEditorController(
        editor,
        followActiveLocation: false,
      );
    });

    tearDown(() async {
      controller.dispose();
      await editor.events.close();
    });

    test('ignores IDE cursor events', () async {
      editor.events.add(
        ActiveLocationChangedEvent(
          selections: [EditorSelection(active: pos1, anchor: pos1)],
          textDocument: doc,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(editor.pending, isEmpty);
      expect(controller.editableWidgetData.value, isNull);
      expect(controller.waitingForFirstEvent, isTrue);
    });

    test('showWidgetAt fetches the widget and clearWidget clears it', () async {
      final shown = controller.showWidgetAt(
        fileUri: doc.uriAsString,
        position: pos1,
      );
      editor.pending[pos1]!.complete(_result('Text'));
      await shown;
      expect(controller.widgetName, 'Text');
      expect(
        controller.editableWidgetData.value!.properties.map((p) => p.name),
        ['data'],
      );
      expect(controller.waitingForFirstEvent, isFalse);

      controller.clearWidget();
      expect(controller.editableWidgetData.value, isNull);
    });

    test('drops stale results when the target changes', () async {
      final first = controller.showWidgetAt(
        fileUri: doc.uriAsString,
        position: pos1,
      );
      final second = controller.showWidgetAt(
        fileUri: doc.uriAsString,
        position: pos2,
      );
      editor.pending[pos2]!.complete(_result('Padding'));
      await second;
      editor.pending[pos1]!.complete(_result('Text'));
      await first;
      expect(controller.widgetName, 'Padding');
    });

    test('edits the shown widget and then re-fetches it', () async {
      final shown = controller.showWidgetAt(
        fileUri: doc.uriAsString,
        position: pos1,
      );
      editor.pending[pos1]!.complete(_result('Text'));
      await shown;
      final firstRequest = editor.pending[pos1];

      final response = await controller.editArgument<String>(
        name: 'data',
        value: 'bye',
      );
      expect(response?.success, isTrue);
      expect(editor.edits, [(doc, pos1, 'data', 'bye')]);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(editor.pending[pos1], isNot(same(firstRequest)));
    });
  });
}
