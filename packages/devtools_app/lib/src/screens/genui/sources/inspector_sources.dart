// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:json_schema_builder/json_schema_builder.dart';

import '../../../service/service_extensions.dart' as extensions;
import '../../../shared/console/eval/inspector_tree.dart';
import '../../../shared/diagnostics/diagnostics_node.dart';
import '../../../shared/diagnostics/primitives/instance_ref.dart';
import '../../../shared/globals.dart';
import '../../inspector/inspector_controller.dart';
import '../../inspector/inspector_data_models.dart';
import '../../inspector/inspector_screen_controller.dart';
import '../../inspector/inspector_tree_controller.dart';
import '../data/actions.dart';
import '../data/data_source.dart';
import '../data/json_utils.dart';

/// Whether the connected app supports the Flutter widget inspector.
bool get inspectorAvailable => serviceConnection.inspectorService != null;

/// The message shown when the inspector is not available.
const inspectorUnavailableMessage =
    'The widget inspector requires a connected Flutter app running in debug '
    'or profile mode.';

/// Returns the shared (v2) inspector controller, the same one the Inspector
/// screen uses.
InspectorController inspectorController() {
  if (!inspectorAvailable) {
    throw GenUiDataException(inspectorUnavailableMessage);
  }
  return screenControllers
      .lookup<InspectorScreenController>()
      .inspectorController;
}

/// A headless [InspectorControllerClient].
///
/// The [InspectorController] only fetches the widget tree and selection while
/// at least one client is attached to its tree controller (normally the
/// Inspector screen's tree widget). GenUI components and data sources attach
/// one of these while they are active so that they work on their own.
class _HeadlessInspectorClient implements InspectorControllerClient {
  @override
  void requestFocus() {}

  @override
  void scrollToRect(Rect rect) {}

  @override
  void waitForClientsThenScrollToRect(Rect rect, {int retries = 0}) {}
}

/// Keeps [controller] active (fetching the tree and selection) until the
/// returned callback is called.
///
/// Like the Inspector screen's tree, activation waits until the main isolate
/// is not paused.
VoidCallback activateInspector(InspectorController controller) {
  final client = _HeadlessInspectorClient();
  final treeController = controller.inspectorTree;
  final isPaused = serviceConnection
      .serviceManager
      .isolateManager
      .mainIsolateState
      ?.isPaused;
  var attached = false;
  var released = false;

  void attach() {
    if (attached || released) return;
    if (isPaused?.value ?? false) return;
    attached = true;
    isPaused?.removeListener(attach);
    treeController.addClient(client);
  }

  isPaused?.addListener(attach);
  attach();
  return () {
    released = true;
    isPaused?.removeListener(attach);
    if (attached) treeController.removeClient(client);
  };
}

JsonObject? _location(RemoteDiagnosticsNode node) {
  final location = node.creationLocation;
  final file = location?.getFile();
  if (location == null || file == null) return null;
  return {
    'file': file,
    'line': location.getLine(),
    'column': location.getColumn(),
  };
}

JsonObject _property(RemoteDiagnosticsNode property) => {
  'name': property.name,
  'value': property.description,
  'type': property.propertyType,
  if (property.level.name != 'info') 'level': property.level.name,
};

double? _finite(double value) => value.isFinite ? value : null;

JsonObject _layout(LayoutProperties layout) {
  final constraints = layout.constraints;
  return {
    'width': layout.size.width,
    'height': layout.size.height,
    if (constraints != null) ...{
      'minWidth': constraints.minWidth,
      'maxWidth': _finite(constraints.maxWidth),
      'minHeight': constraints.minHeight,
      'maxHeight': _finite(constraints.maxHeight),
    },
    'isFlex': layout.isFlex,
    'flexFactor': layout.flexFactor,
    'flexFit': layout.flexFit?.name,
    'isOverflowWidth': layout.isOverflowWidth,
    'isOverflowHeight': layout.isOverflowHeight,
    'children': [
      for (final child in layout.displayChildren)
        {
          'description': child.description,
          'width': child.size.width,
          'height': child.size.height,
          'flexFactor': child.flexFactor,
        },
    ],
  };
}

/// Projects the selected widget and its loaded properties into JSON.
@visibleForTesting
JsonObject? projectInspectorSelection(
  RemoteDiagnosticsNode? node,
  WidgetTreeNodeProperties properties,
) {
  if (node == null) return null;
  final layout = properties.layoutProperties;
  return {
    'id': node.valueRef.id,
    'widget': node.widgetRuntimeType ?? node.description,
    'description': node.description,
    'isCreatedByLocalProject': node.isCreatedByLocalProject,
    'location': _location(node),
    'properties': [for (final p in properties.widgetProperties) _property(p)],
    'renderProperties': [
      for (final p in properties.renderProperties)
        if (p.propertyType != 'RenderObject') _property(p),
    ],
    'layout': layout == null ? null : _layout(layout),
  };
}

/// Flattens the loaded widget tree under [root] into rows, depth first.
@visibleForTesting
List<JsonObject> projectWidgetTree(
  InspectorTreeNode? root, {
  bool localOnly = false,
  int? maxDepth,
  int limit = 2000,
}) {
  final rows = <JsonObject>[];
  void visit(InspectorTreeNode node, int depth) {
    if (rows.length >= limit) return;
    final diagnostic = node.diagnostic;
    var childDepth = depth;
    if (diagnostic != null &&
        (!localOnly || diagnostic.isCreatedByLocalProject)) {
      if (maxDepth != null && depth > maxDepth) return;
      final location = _location(diagnostic);
      rows.add({
        'id': diagnostic.valueRef.id,
        'depth': depth,
        'widget': diagnostic.widgetRuntimeType ?? diagnostic.description,
        'description': diagnostic.description,
        'isCreatedByLocalProject': diagnostic.isCreatedByLocalProject,
        'hasChildren': node.children.isNotEmpty || diagnostic.hasChildren,
        'selected': node.selected,
        'file': location?['file'],
        'line': location?['line'],
      });
      childDepth = depth + 1;
    }
    for (final child in node.children) {
      visit(child, childDepth);
    }
  }

  if (root != null) visit(root, 0);
  return rows;
}

/// Opens a stream that keeps the inspector active and re-projects whenever
/// any of the controller's [listenables] change.
Stream<Object?> _inspectorStream(
  List<Listenable> Function(InspectorController controller) listenables,
  Object? Function(InspectorController controller) project,
) {
  late final StreamController<Object?> output;
  VoidCallback? deactivate;
  StreamSubscription<Object?>? subscription;
  output = StreamController<Object?>(
    onListen: () {
      try {
        final controller = inspectorController();
        deactivate = activateInspector(controller);
        subscription = streamFromListenables(
          listenables(controller),
          () => project(controller),
        ).listen(output.add, onError: output.addError, onDone: output.close);
      } catch (e, st) {
        output.addError(e, st);
      }
    },
    onCancel: () async {
      deactivate?.call();
      await subscription?.cancel();
    },
  );
  return output.stream;
}

/// The inspector overlay toggles the agent can control.
final _overlays = {
  'debugPaint': extensions.debugPaint,
  'debugPaintBaselines': extensions.debugPaintBaselines,
  'repaintRainbow': extensions.repaintRainbow,
  'slowAnimations': extensions.slowAnimations,
  'invertOversizedImages': extensions.invertOversizedImages,
};

bool _extensionEnabled(String name) => serviceConnection
    .serviceManager
    .serviceExtensionManager
    .getServiceExtensionState(name)
    .value
    .enabled;

String get _selectModeExtension =>
    serviceConnection.serviceManager.serviceExtensionManager
        .hasServiceExtension(extensions.toggleSelectWidgetMode.extension)
        .value
    ? extensions.toggleSelectWidgetMode.extension
    : extensions.toggleOnDeviceWidgetInspector.extension;

Future<void> _setExtension(
  extensions.ToggleableServiceExtensionDescription<Object> description,
  bool enabled,
) => serviceConnection.serviceManager.serviceExtensionManager
    .setServiceExtensionState(
      description.extension,
      enabled: enabled,
      value: enabled ? description.enabledValue : description.disabledValue,
    );

/// Data sources backed by the Flutter widget inspector.
List<DataSourceDescriptor> inspectorDataSources() => [
  DataSourceDescriptor(
    id: 'inspector.selection',
    description:
        'The widget currently selected in the Flutter inspector (selected in '
        'DevTools, via `inspector.selectWidget`, or on the device in select '
        'mode), or null. Includes the source `location`, widget '
        '`properties` and `renderProperties` ({name, value, type}), and '
        '`layout` (size, constraints, flex info, children sizes). Flutter '
        'apps only.',
    paramsSchema: S.object(),
    outputSchema: S.object(
      properties: {
        'id': S.string(description: 'Inspector id (use with selectWidget).'),
        'widget': S.string(description: 'Widget type, e.g. "Padding".'),
        'description': S.string(),
        'isCreatedByLocalProject': S.boolean(),
        'location': S.object(
          properties: {
            'file': S.string(),
            'line': S.integer(),
            'column': S.integer(),
          },
        ),
        'properties': S.list(items: S.object()),
        'renderProperties': S.list(items: S.object()),
        'layout': S.object(),
      },
    ),
    exampleExpressions: [
      'properties',
      '{widget: widget, width: layout.width, height: layout.height}',
      "renderProperties[?name=='constraints'].value | [0]",
    ],
    open: (context, params) => _inspectorStream(
      (c) => [c.selectedNode, c.selectedNodeProperties],
      (c) => projectInspectorSelection(
        c.selectedDiagnostic,
        c.selectedNodeProperties.value,
      ),
    ),
  ),
  DataSourceDescriptor(
    id: 'inspector.widgetTree',
    description:
        'The Flutter widget tree as flat rows in depth-first order '
        '({id, depth, widget, description, isCreatedByLocalProject, '
        'hasChildren, selected, file, line}). By default this is the '
        'summary tree (implementation widgets hidden, like the Inspector '
        'screen). Updates when the tree is refreshed or the selection '
        'changes. Flutter apps only.',
    paramsSchema: S.object(
      properties: {
        'localOnly': S.boolean(
          description:
              'Only include widgets created by the app\'s own code; depth '
              'counts only included widgets (default false).',
        ),
        'maxDepth': S.integer(description: 'Maximum depth to include.'),
        'limit': S.integer(
          description: 'Maximum number of rows (default 2000).',
          minimum: 1,
        ),
      },
    ),
    outputSchema: S.list(
      items: S.object(
        properties: {
          'id': S.string(),
          'depth': S.integer(),
          'widget': S.string(),
          'description': S.string(),
          'isCreatedByLocalProject': S.boolean(),
          'hasChildren': S.boolean(),
          'selected': S.boolean(),
          'file': S.string(),
          'line': S.integer(),
        },
      ),
    ),
    exampleExpressions: ["[?widget=='Text']", 'length(@)', '[?selected] | [0]'],
    open: (context, params) {
      final localOnly = params['localOnly'] == true;
      final maxDepth = (params['maxDepth'] as num?)?.toInt();
      final limit = (params['limit'] as num?)?.toInt() ?? 2000;
      return _inspectorStream(
        (c) => [c.inspectorTree.rowsInTree, c.selectedNode],
        (c) => projectWidgetTree(
          c.inspectorTree.root,
          localOnly: localOnly,
          maxDepth: maxDepth,
          limit: limit,
        ),
      );
    },
  ),
  DataSourceDescriptor(
    id: 'inspector.status',
    description:
        'Inspector state: `{selectMode, implementationWidgetsHidden, '
        'overlays: {debugPaint, debugPaintBaselines, repaintRainbow, '
        'slowAnimations, invertOversizedImages}}` (booleans). Flutter apps '
        'only.',
    paramsSchema: S.object(),
    outputSchema: S.object(
      properties: {
        'selectMode': S.boolean(),
        'implementationWidgetsHidden': S.boolean(),
        'overlays': S.object(),
      },
    ),
    exampleExpressions: ['overlays.debugPaint'],
    open: (context, params) {
      if (!inspectorAvailable) {
        return Stream.error(GenUiDataException(inspectorUnavailableMessage));
      }
      final manager = serviceConnection.serviceManager.serviceExtensionManager;
      final controller = inspectorController();
      return streamFromListenables(
        [
          controller.implementationWidgetsHidden,
          manager.getServiceExtensionState(_selectModeExtension),
          for (final e in _overlays.values)
            manager.getServiceExtensionState(e.extension),
        ],
        () => {
          'selectMode': _extensionEnabled(_selectModeExtension),
          'implementationWidgetsHidden':
              controller.implementationWidgetsHidden.value,
          'overlays': {
            for (final MapEntry(:key, :value) in _overlays.entries)
              key: _extensionEnabled(value.extension),
          },
        },
      );
    },
  ),
];

/// Actions backed by the Flutter widget inspector.
List<ActionDescriptor> inspectorActions() => [
  ActionDescriptor(
    id: 'inspector.selectWidget',
    description:
        'Selects a widget by inspector `id` (from inspector.widgetTree or '
        'inspector.selection) in DevTools, and highlights it on the device.',
    argsSchema: S.object(properties: {'id': S.string()}, required: ['id']),
    run: (context, args) async {
      final id = args['id'];
      if (id is! String) throw GenUiDataException('Missing widget `id`.');
      final controller = inspectorController();
      final node =
          controller.valueToInspectorTreeNode[InspectorInstanceRef(id)];
      if (node == null) {
        throw GenUiDataException(
          'Widget $id is not in the current widget tree. Refresh the tree '
          'or pick an id from inspector.widgetTree.',
        );
      }
      controller
        ..setSelectedNode(node)
        ..syncSelectionHelper(
          selection: node.diagnostic,
          notifyFlutterInspector: true,
        )
        ..syncTreeSelection();
      return null;
    },
  ),
  ActionDescriptor(
    id: 'inspector.refresh',
    description: 'Refreshes the widget tree from the app.',
    run: (context, args) async {
      await inspectorController().refreshInspector(isManualRefresh: true);
      return null;
    },
  ),
  ActionDescriptor(
    id: 'inspector.toggleImplementationWidgets',
    description:
        'Shows or hides implementation widgets (created by the framework or '
        'other packages) in the widget tree.',
    run: (context, args) async {
      await inspectorController().toggleImplementationWidgetsVisibility();
      return null;
    },
  ),
  ActionDescriptor(
    id: 'inspector.setSelectMode',
    description:
        'Enables or disables widget select mode on the device: tapping a '
        'widget in the app selects it in DevTools.',
    mutatesApp: true,
    argsSchema: S.object(
      properties: {'enabled': S.boolean()},
      required: ['enabled'],
    ),
    run: (context, args) async {
      if (!inspectorAvailable) {
        throw GenUiDataException(inspectorUnavailableMessage);
      }
      final supportsSelectMode = serviceConnection
          .serviceManager
          .serviceExtensionManager
          .hasServiceExtension(extensions.toggleSelectWidgetMode.extension)
          .value;
      await _setExtension(
        supportsSelectMode
            ? extensions.toggleSelectWidgetMode
            : extensions.toggleOnDeviceWidgetInspector,
        args['enabled'] == true,
      );
      return null;
    },
  ),
  ActionDescriptor(
    id: 'inspector.setOverlay',
    description:
        'Turns a debugging overlay on or off in the app: debugPaint, '
        'debugPaintBaselines, repaintRainbow, slowAnimations, or '
        'invertOversizedImages.',
    mutatesApp: true,
    argsSchema: S.object(
      properties: {
        'overlay': S.string(enumValues: _overlays.keys.toList()),
        'enabled': S.boolean(),
      },
      required: ['overlay', 'enabled'],
    ),
    run: (context, args) async {
      if (!inspectorAvailable) {
        throw GenUiDataException(inspectorUnavailableMessage);
      }
      final description = _overlays[args['overlay']];
      if (description == null) {
        throw GenUiDataException(
          'Unknown overlay "${args['overlay']}". Expected one of '
          '${_overlays.keys.join(', ')}.',
        );
      }
      await _setExtension(description, args['enabled'] == true);
      return null;
    },
  ),
];
