// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'package:devtools_app_shared/ui.dart';
import 'package:genui/genui.dart';
import 'package:json_schema_builder/json_schema_builder.dart';
import 'package:material_ui/material_ui.dart';

import '../../inspector/inspector_controller.dart';
import '../../inspector/inspector_controls.dart';
import '../../inspector/inspector_tree_controller.dart';
import '../../inspector/layout_explorer/box/box.dart';
import '../../inspector/layout_explorer/flex/flex.dart';
import '../../inspector/widget_details.dart';
import '../../inspector/widget_properties/properties_view.dart';
import '../data/json_utils.dart';
import '../sources/inspector_sources.dart';
import 'layout_safety.dart';

/// Hosts an inspector component: checks that the inspector is available,
/// keeps the shared [InspectorController] active while mounted, and gives the
/// component a fixed height.
class InspectorHost extends StatefulWidget {
  const InspectorHost({super.key, required this.height, required this.builder});

  final double height;
  final Widget Function(BuildContext context, InspectorController controller)
  builder;

  @override
  State<InspectorHost> createState() => _InspectorHostState();
}

class _InspectorHostState extends State<InspectorHost> {
  InspectorController? _controller;
  VoidCallback? _deactivate;

  @override
  void initState() {
    super.initState();
    if (inspectorAvailable) {
      final controller = inspectorController();
      _controller = controller;
      _deactivate = activateInspector(controller);
    }
  }

  @override
  void dispose() {
    _deactivate?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return BoundedWidth(
      child: SizedBox(
        height: widget.height,
        child: controller == null
            ? RoundedOutlinedBorder(
                child: Center(
                  child: Text(
                    inspectorUnavailableMessage,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).subtleTextStyle,
                  ),
                ),
              )
            : widget.builder(context, controller),
      ),
    );
  }
}

double _height(JsonObject data, double defaultHeight) =>
    (data['height'] as num?)?.toDouble() ?? defaultHeight;

Schema _heightSchema(num defaultHeight) =>
    S.number(description: 'Height in pixels (default $defaultHeight).');

const _sharedSelectionNote =
    'All inspector components share one selection (the same as the '
    'Inspector screen): selecting in the WidgetTree, on the device, or via '
    '`inspector.selectWidget` updates them all. Flutter apps only.';

/// The real Inspector screen widget tree.
CatalogItem widgetTreeCatalogItem() => CatalogItem(
  name: 'WidgetTree',
  dataSchema: S.object(
    description:
        'The Flutter Inspector\'s interactive widget tree (expand, collapse, '
        'search, select). $_sharedSelectionNote',
    properties: {'height': _heightSchema(400)},
  ),
  isImplicitlyFlexible: true,
  widgetBuilder: (itemContext) {
    final data = itemContext.data as JsonObject;
    return InspectorHost(
      height: _height(data, 400),
      builder: (context, controller) => RoundedOutlinedBorder(
        clip: true,
        child: InspectorTree(
          controller: controller,
          treeController: controller.inspectorTree,
        ),
      ),
    );
  },
);

/// The real Inspector screen details panel for the selected widget.
CatalogItem widgetDetailsCatalogItem() => CatalogItem(
  name: 'WidgetDetails',
  dataSchema: S.object(
    description:
        'The Flutter Inspector\'s details panel for the selected widget: '
        'tabs for widget properties (with a box layout diagram), render '
        'object properties, and the flex layout explorer. '
        '$_sharedSelectionNote',
    properties: {'height': _heightSchema(400)},
  ),
  isImplicitlyFlexible: true,
  widgetBuilder: (itemContext) {
    final data = itemContext.data as JsonObject;
    return InspectorHost(
      height: _height(data, 400),
      builder: (context, controller) => WidgetDetails(controller: controller),
    );
  },
);

/// The layout explorer for the selected widget.
CatalogItem layoutExplorerCatalogItem() => CatalogItem(
  name: 'LayoutExplorer',
  dataSchema: S.object(
    description:
        'Layout visualization for the selected widget: the interactive flex '
        'explorer (main/cross axis alignment, flex factors) for Row, Column, '
        'Flex and their children, otherwise the box layout diagram (size, '
        'padding, constraints). $_sharedSelectionNote',
    properties: {'height': _heightSchema(320)},
  ),
  isImplicitlyFlexible: true,
  widgetBuilder: (itemContext) {
    final data = itemContext.data as JsonObject;
    return InspectorHost(
      height: _height(data, 320),
      builder: (context, controller) => _LayoutExplorer(controller: controller),
    );
  },
);

class _LayoutExplorer extends StatelessWidget {
  const _LayoutExplorer({required this.controller});

  final InspectorController controller;

  @override
  Widget build(BuildContext context) {
    return RoundedOutlinedBorder(
      clip: true,
      child: ValueListenableBuilder(
        valueListenable: controller.selectedNodeProperties,
        builder: (context, properties, _) {
          final node = controller.selectedDiagnostic;
          if (node == null) {
            return const Center(child: Text('Select a widget.'));
          }
          if (FlexLayoutExplorerWidget.shouldDisplay(node)) {
            return FlexLayoutExplorerWidget(controller);
          }
          return Padding(
            padding: const EdgeInsets.all(denseSpacing),
            child: BoxLayoutExplorerWidget(
              layoutProperties: properties.layoutProperties,
              selectedNode: node,
            ),
          );
        },
      ),
    );
  }
}

/// A properties table for the selected widget or its render object.
CatalogItem widgetPropertiesCatalogItem() => CatalogItem(
  name: 'WidgetProperties',
  dataSchema: S.object(
    description:
        'Properties table (name and value) for the selected widget, or its '
        'render object. $_sharedSelectionNote',
    properties: {
      'target': S.string(
        description: '"widget" (default) or "renderObject".',
        enumValues: ['widget', 'renderObject'],
      ),
      'height': _heightSchema(300),
    },
  ),
  isImplicitlyFlexible: true,
  widgetBuilder: (itemContext) {
    final data = itemContext.data as JsonObject;
    final renderObject = data['target'] == 'renderObject';
    return InspectorHost(
      height: _height(data, 300),
      builder: (context, controller) =>
          _PropertiesPanel(controller: controller, renderObject: renderObject),
    );
  },
);

class _PropertiesPanel extends StatefulWidget {
  const _PropertiesPanel({
    required this.controller,
    required this.renderObject,
  });

  final InspectorController controller;
  final bool renderObject;

  @override
  State<_PropertiesPanel> createState() => _PropertiesPanelState();
}

class _PropertiesPanelState extends State<_PropertiesPanel> {
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RoundedOutlinedBorder(
      clip: true,
      child: ValueListenableBuilder(
        valueListenable: widget.controller.selectedNodeProperties,
        builder: (context, properties, _) {
          if (widget.controller.selectedDiagnostic == null) {
            return const Center(child: Text('Select a widget.'));
          }
          final list = widget.renderObject
              ? properties.renderProperties
                    .where((p) => p.propertyType != 'RenderObject')
                    .toList()
              : properties.widgetProperties;
          if (list.isEmpty) {
            return const Center(child: Text('No properties.'));
          }
          return PropertiesTable(
            properties: list,
            scrollController: _scrollController,
          );
        },
      ),
    );
  }
}

/// The Inspector screen's control bar.
CatalogItem inspectorControlsCatalogItem() => CatalogItem(
  name: 'InspectorControls',
  dataSchema: S.object(
    description:
        'The Flutter Inspector\'s toolbar: toggle widget select mode on the '
        'device, show/hide implementation widgets, and debugging overlays '
        '(slow animations, debug paint, paint baselines, repaint rainbow, '
        'invert oversized images). Flutter apps only.',
    properties: {},
  ),
  isImplicitlyFlexible: true,
  widgetBuilder: (itemContext) => InspectorHost(
    height: defaultButtonHeight + 2 * densePadding,
    builder: (context, controller) => InspectorControls(controller: controller),
  ),
);

/// All inspector catalog items.
List<CatalogItem> inspectorCatalogItems() => [
  widgetTreeCatalogItem(),
  widgetDetailsCatalogItem(),
  layoutExplorerCatalogItem(),
  widgetPropertiesCatalogItem(),
  inspectorControlsCatalogItem(),
];
