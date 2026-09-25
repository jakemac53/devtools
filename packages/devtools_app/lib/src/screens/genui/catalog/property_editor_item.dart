// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'dart:async';

import 'package:devtools_app_shared/ui.dart';
import 'package:devtools_app_shared/utils.dart';
import 'package:dtd/dtd.dart';
import 'package:flutter/material.dart';
import 'package:genui/genui.dart';
import 'package:json_schema_builder/json_schema_builder.dart';

import '../../../shared/diagnostics/diagnostics_node.dart';
import '../../../shared/editor/api_classes.dart';
import '../../../shared/editor/editor_client.dart';
import '../../../shared/globals.dart';
import '../../../shared/ui/common_widgets.dart';
import '../../../standalone_ui/ide_shared/property_editor/property_editor_controller.dart';
import '../../../standalone_ui/ide_shared/property_editor/property_editor_view.dart';
import '../../inspector_v2/inspector_controller.dart';
import '../data/json_utils.dart';
import 'inspector_items.dart';
import 'layout_safety.dart';

/// A source location that the property editor can show, derived from a
/// widget's creation location.
typedef PropertyEditorTarget = ({String fileUri, CursorPosition position});

/// Returns the property editor target for the widget described by [node], or
/// null if the widget was not created by the local project or has no usable
/// creation location.
///
/// Inspector creation locations are 1-based, while the property editor (LSP)
/// uses 0-based lines and characters.
PropertyEditorTarget? propertyEditorTargetFor(RemoteDiagnosticsNode? node) {
  if (node == null || !node.isCreatedByLocalProject) return null;
  final location = node.creationLocation;
  final file = location?.getFile();
  if (location == null || file == null) return null;
  final line = location.getLine();
  final column = location.getColumn();
  if (line < 1 || column < 1) return null;
  final String fileUri;
  if (file.startsWith('file:')) {
    fileUri = file;
  } else if (file.startsWith('/')) {
    fileUri = Uri.file(file).toString();
  } else {
    // For example, `org-dartlang-app:` URIs on the web cannot be resolved by
    // the analysis server.
    return null;
  }
  return (
    fileUri: fileUri,
    position: CursorPosition(line: line - 1, character: column - 1),
  );
}

DartToolingDaemon? _sharedDtd;
EditorClient? _sharedEditorClient;

/// Returns an [EditorClient] for [dtd], shared by all GenUI property editors.
///
/// A DTD connection may only listen to each stream once, so a single client
/// is shared per connection.
EditorClient _editorClientFor(DartToolingDaemon dtd) {
  if (!identical(dtd, _sharedDtd) || _sharedEditorClient == null) {
    _sharedEditorClient?.dispose();
    _sharedDtd = dtd;
    _sharedEditorClient = EditorClient(dtd);
  }
  return _sharedEditorClient!;
}

const _defaultHeight = 450.0;

/// The IDE property editor: view and edit the constructor arguments of a
/// widget in the source code.
CatalogItem propertyEditorCatalogItem() => CatalogItem(
  name: 'PropertyEditor',
  dataSchema: S.object(
    description:
        'The Flutter Property Editor: view and edit the constructor arguments '
        '(properties) of a widget in the app\'s source code, with typed '
        'inputs (enums, bools, numbers, strings), docs and filtering. With '
        'source "inspector" (default) it edits the widget currently selected '
        'in the inspector (WidgetTree, on-device select mode or '
        '`inspector.selectWidget`); with source "editor" it follows the IDE '
        'cursor. Edits are applied to the source in the IDE (save and hot '
        'reload to see them). Requires an IDE with the Dart extension '
        'connected through the Dart Tooling Daemon (DTD).',
    properties: {
      'source': S.string(
        description:
            '"inspector" (default): the selected widget. "editor": the '
            'widget at the IDE cursor.',
        enumValues: ['inspector', 'editor'],
      ),
      'height': S.number(
        description: 'Height in pixels (default $_defaultHeight).',
      ),
    },
  ),
  isImplicitlyFlexible: true,
  widgetBuilder: (itemContext) {
    final data = itemContext.data as JsonObject;
    final height = (data['height'] as num?)?.toDouble() ?? _defaultHeight;
    if (data['source'] == 'editor') {
      return BoundedWidth(
        child: SizedBox(height: height, child: const _DtdGate(inspector: null)),
      );
    }
    return InspectorHost(
      height: height,
      builder: (context, inspector) => _DtdGate(inspector: inspector),
    );
  },
);

/// Shows the property editor once DevTools is connected to DTD, otherwise a
/// message explaining how to connect.
class _DtdGate extends StatelessWidget {
  const _DtdGate({required this.inspector});

  /// The inspector whose selection drives the property editor, or null to
  /// follow the IDE cursor.
  final InspectorController? inspector;

  @override
  Widget build(BuildContext context) {
    return RoundedOutlinedBorder(
      clip: true,
      child: ValueListenableBuilder<DartToolingDaemon?>(
        valueListenable: dtdManager.connection,
        builder: (context, dtd, _) {
          if (dtd == null) return const _NoDtdMessage();
          return _GenUiPropertyEditor(
            key: ObjectKey(dtd),
            dtd: dtd,
            inspector: inspector,
          );
        },
      ),
    );
  }
}

class _NoDtdMessage extends StatefulWidget {
  const _NoDtdMessage();

  @override
  State<_NoDtdMessage> createState() => _NoDtdMessageState();
}

class _NoDtdMessageState extends State<_NoDtdMessage> {
  final _uriController = TextEditingController();
  String? _error;
  bool _connecting = false;

  @override
  void dispose() {
    _uriController.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final uri = Uri.tryParse(_uriController.text.trim());
    if (uri == null || !uri.hasScheme) {
      setState(() => _error = 'Enter a ws:// URI.');
      return;
    }
    setState(() {
      _connecting = true;
      _error = null;
    });
    await dtdManager.connect(
      uri,
      onError: (e, _) {
        if (mounted) setState(() => _error = 'Could not connect: $e');
      },
    );
    if (mounted) setState(() => _connecting = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(defaultSpacing),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            'The property editor edits your source code through your IDE, so '
            'DevTools must be connected to the Dart Tooling Daemon (DTD) of '
            'an IDE running the Dart extension. Open DevTools from the IDE, or '
            'paste the IDE\'s DTD URI below.',
            textAlign: TextAlign.center,
            style: theme.subtleTextStyle,
          ),
          const SizedBox(height: defaultSpacing),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _uriController,
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: 'ws://127.0.0.1:1234/abcd=',
                  ),
                  onSubmitted: (_) => unawaited(_connect()),
                ),
              ),
              const SizedBox(width: denseSpacing),
              FilledButton(
                onPressed: _connecting ? null : () => unawaited(_connect()),
                child: const Text('Connect'),
              ),
            ],
          ),
          if (_error case final error?) ...[
            const SizedBox(height: denseSpacing),
            Text(error, style: TextStyle(color: theme.colorScheme.error)),
          ],
        ],
      ),
    );
  }
}

class _GenUiPropertyEditor extends StatefulWidget {
  const _GenUiPropertyEditor({
    super.key,
    required this.dtd,
    required this.inspector,
  });

  final DartToolingDaemon dtd;
  final InspectorController? inspector;

  @override
  State<_GenUiPropertyEditor> createState() => _GenUiPropertyEditorState();
}

class _GenUiPropertyEditorState extends State<_GenUiPropertyEditor>
    with AutoDisposeMixin {
  late final Future<PropertyEditorController> _controllerFuture;
  PropertyEditorController? _controller;
  final _scrollController = ScrollController();

  /// The reason no widget can be shown for the inspector selection, if any.
  final _selectionProblem = ValueNotifier<String?>(null);

  @override
  void initState() {
    super.initState();
    final editor = _editorClientFor(widget.dtd);
    _controllerFuture = editor.initialized.then((_) {
      final controller = PropertyEditorController(
        editor,
        followActiveLocation: widget.inspector == null,
      );
      if (!mounted) {
        controller.dispose();
        return controller;
      }
      _controller = controller;
      final inspector = widget.inspector;
      if (inspector != null) {
        addAutoDisposeListener(inspector.selectedNode, _syncSelection);
        _syncSelection();
      }
      return controller;
    });
  }

  void _syncSelection() {
    final controller = _controller;
    final inspector = widget.inspector;
    if (controller == null || inspector == null) return;
    final node = inspector.selectedNode.value?.diagnostic;
    final target = propertyEditorTargetFor(node);
    if (target == null) {
      _selectionProblem.value = node == null
          ? 'Select a widget in the widget tree or on the device.'
          : '${node.description ?? 'This widget'} was not created by your '
                'project, so it has no source to edit. Select a widget '
                'created by your project.';
      controller.clearWidget();
      return;
    }
    _selectionProblem.value = null;
    unawaited(
      controller.showWidgetAt(
        fileUri: target.fileUri,
        position: target.position,
      ),
    );
  }

  @override
  void dispose() {
    _controller?.dispose();
    _scrollController.dispose();
    _selectionProblem.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PropertyEditorController>(
      future: _controllerFuture,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _Message('Could not connect to the editor: ${snapshot.error}');
        }
        final controller = snapshot.data;
        if (controller == null) {
          return const CenteredCircularProgressIndicator();
        }
        return MultiValueListenableBuilder(
          listenables: [
            controller.editorClient.editableArgumentsApiIsRegistered,
            controller.shouldReconnect,
            _selectionProblem,
          ],
          builder: (context, values, _) {
            final registered = values[0] as bool;
            final shouldReconnect = values[1] as bool;
            final selectionProblem = values[2] as String?;
            if (shouldReconnect) {
              return const _Message(
                'The connection to the Dart Tooling Daemon was closed.',
              );
            }
            if (!registered) {
              return const _Message(
                'Waiting for an IDE with the Dart extension to provide the '
                'property editor API over DTD. Make sure a Dart/Flutter '
                'project is open in the IDE connected to this DTD.',
                showProgress: true,
              );
            }
            if (selectionProblem != null) return _Message(selectionProblem);
            return Column(
              children: [
                Expanded(
                  child: Scrollbar(
                    controller: _scrollController,
                    thumbVisibility: true,
                    child: SingleChildScrollView(
                      controller: _scrollController,
                      padding: const EdgeInsets.fromLTRB(
                        denseSpacing,
                        denseSpacing,
                        defaultSpacing, // Additional right padding for scroll bar.
                        denseSpacing,
                      ),
                      child: PropertyEditorView(controller: controller),
                    ),
                  ),
                ),
                const PaddedDivider.noPadding(),
                Padding(
                  padding: const EdgeInsets.all(densePadding),
                  child: Text(
                    'Edits change your source code in the IDE. Save and hot '
                    'reload to see them in the app.',
                    style: Theme.of(context).subtleTextStyle,
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.message, {this.showProgress = false});

  final String message;
  final bool showProgress;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(defaultSpacing),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showProgress) ...[
              const SizedBox.square(
                dimension: defaultIconSize,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(height: denseSpacing),
            ],
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).subtleTextStyle,
            ),
          ],
        ),
      ),
    );
  }
}
