// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'dart:async';

import 'package:devtools_app_shared/ui.dart';
import 'package:genui/genui.dart';
import 'package:material_ui/material_ui.dart';

import '../../shared/config_specific/copy_to_clipboard/copy_to_clipboard.dart';
import '../../shared/framework/screen.dart';
import '../../shared/globals.dart';
import 'genui_controller.dart';
import 'genui_store.dart';

/// An experimental screen where an agent builds custom DevTools screens out
/// of DevTools components, bound to live data from the connected app.
class GenUiScreen extends Screen {
  GenUiScreen() : super.fromMetaData(ScreenMetaData.genUi);

  static final id = ScreenMetaData.genUi.id;

  @override
  bool get experimentEnabled => preferences.genUiEnabled.value;

  @override
  Widget buildScreenBody(BuildContext context) => const GenUiScreenBody();
}

class GenUiScreenBody extends StatefulWidget {
  const GenUiScreenBody({super.key});

  @override
  State<GenUiScreenBody> createState() => _GenUiScreenBodyState();
}

class _GenUiScreenBodyState extends State<GenUiScreenBody> {
  late final GenUiController controller;
  var _showChat = true;

  @override
  void initState() {
    super.initState();
    controller = screenControllers.lookup<GenUiController>();
  }

  @override
  Widget build(BuildContext context) {
    final canvas = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Toolbar(
          controller: controller,
          showChat: _showChat,
          onToggleChat: () => setState(() => _showChat = !_showChat),
        ),
        const SizedBox(height: denseSpacing),
        Expanded(child: _Canvas(controller: controller)),
      ],
    );
    if (!_showChat) return canvas;
    return SplitPane(
      axis: Axis.horizontal,
      initialFractions: const [0.7, 0.3],
      children: [
        Padding(
          padding: const EdgeInsets.only(right: densePadding),
          child: canvas,
        ),
        OutlineDecoration(child: _ChatPanel(controller: controller)),
      ],
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.controller,
    required this.showChat,
    required this.onToggleChat,
  });

  final GenUiController controller;
  final bool showChat;
  final VoidCallback onToggleChat;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        DevToolsButton(
          icon: Icons.content_copy,
          label: 'Copy spec',
          tooltip:
              'Copy the generated screen as a replayable A2UI spec. Specs '
              'contain no app data and can be loaded without an API key.',
          onPressed: () => unawaited(
            copyToClipboard(
              controller.exportSpec(),
              successMessage: 'Copied GenUI spec to clipboard.',
            ),
          ),
        ),
        const SizedBox(width: denseSpacing),
        DevToolsButton(
          icon: Icons.upload,
          label: 'Load spec',
          onPressed: () => unawaited(_showLoadDialog(context)),
        ),
        const SizedBox(width: denseSpacing),
        ValueListenableBuilder<List<String>>(
          valueListenable: controller.surfaceIds,
          builder: (context, surfaceIds, _) => DevToolsButton(
            icon: Icons.star_border,
            label: 'Save page',
            tooltip: 'Save the current page to your saved pages.',
            onPressed: surfaceIds.isEmpty
                ? null
                : () => unawaited(_showSaveDialog(context)),
          ),
        ),
        const SizedBox(width: denseSpacing),
        _SavedPagesMenu(controller: controller),
        const SizedBox(width: denseSpacing),
        DevToolsButton(
          icon: Icons.delete_outline,
          label: 'Clear',
          onPressed: controller.clearSurfaces,
        ),
        const Spacer(),
        DevToolsButton(
          icon: showChat ? Icons.chevron_right : Icons.chat_outlined,
          label: showChat ? 'Hide chat' : 'Show chat',
          onPressed: onToggleChat,
        ),
      ],
    );
  }

  Future<void> _showSaveDialog(BuildContext context) async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => const _TextInputDialog(
        title: 'Save page',
        submitLabel: 'SAVE',
        width: 400,
        labelText: 'Name',
        helperText: 'Saving with an existing name replaces that page.',
        submitOnEnter: true,
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    await controller.saveCurrentPage(name);
    notificationService.push('Saved page "${name.trim()}".');
  }

  Future<void> _showLoadDialog(BuildContext context) async {
    final spec = await showDialog<String>(
      context: context,
      builder: (context) => const _TextInputDialog(
        title: 'Load GenUI spec',
        submitLabel: 'LOAD',
        width: 600,
        hintText: 'Paste a spec copied with "Copy spec"',
        maxLines: 16,
      ),
    );
    if (spec == null || spec.trim().isEmpty) return;
    try {
      controller.loadSpec(spec);
    } catch (e) {
      notificationService.pushError(
        'Invalid GenUI spec: $e',
        isReportable: false,
      );
    }
  }
}

/// A dialog with a single text field that pops with the entered text.
///
/// The dialog owns its [TextEditingController] so that the controller lives
/// as long as the [TextField], including during the route's exit animation.
class _TextInputDialog extends StatefulWidget {
  const _TextInputDialog({
    required this.title,
    required this.submitLabel,
    required this.width,
    this.labelText,
    this.helperText,
    this.hintText,
    this.maxLines = 1,
    this.submitOnEnter = false,
  });

  final String title;
  final String submitLabel;
  final double width;
  final String? labelText;
  final String? helperText;
  final String? hintText;
  final int maxLines;
  final bool submitOnEnter;

  @override
  State<_TextInputDialog> createState() => _TextInputDialogState();
}

class _TextInputDialogState extends State<_TextInputDialog> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_text.text);

  @override
  Widget build(BuildContext context) {
    return DevToolsDialog(
      title: DialogTitleText(widget.title),
      content: SizedBox(
        width: widget.width,
        child: TextField(
          controller: _text,
          autofocus: true,
          maxLines: widget.maxLines,
          decoration: InputDecoration(
            labelText: widget.labelText,
            helperText: widget.helperText,
            hintText: widget.hintText,
          ),
          onSubmitted: widget.submitOnEnter ? (_) => _submit() : null,
        ),
      ),
      actions: [
        const DialogCancelButton(),
        DialogTextButton(onPressed: _submit, child: Text(widget.submitLabel)),
      ],
    );
  }
}

/// A menu listing the user's saved pages, to load or delete them.
class _SavedPagesMenu extends StatelessWidget {
  const _SavedPagesMenu({required this.controller});

  final GenUiController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<SavedGenUiPage>>(
      valueListenable: controller.savedPages,
      builder: (context, pages, _) => MenuAnchor(
        menuChildren: [
          for (final page in pages)
            MenuItemButton(
              onPressed: () => controller.loadSavedPage(page),
              trailingIcon: IconButton(
                icon: const Icon(Icons.delete_outline, size: defaultIconSize),
                tooltip: 'Delete saved page',
                onPressed: () =>
                    unawaited(controller.deleteSavedPage(page.name)),
              ),
              child: Text(page.name),
            ),
        ],
        builder: (context, menuController, _) => DevToolsButton(
          icon: Icons.star,
          label: 'Saved pages',
          tooltip: pages.isEmpty
              ? 'No saved pages yet. Use "Save page" to save one.'
              : 'Open a saved page.',
          onPressed: pages.isEmpty
              ? null
              : () => menuController.isOpen
                    ? menuController.close()
                    : menuController.open(),
        ),
      ),
    );
  }
}

class _Canvas extends StatelessWidget {
  const _Canvas({required this.controller});

  final GenUiController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<String>>(
      valueListenable: controller.surfaceIds,
      builder: (context, surfaceIds, _) {
        if (surfaceIds.isEmpty) {
          return Center(
            child: Text(
              'Ask the agent to build a screen, e.g. "Show failed network '
              'requests with details for the selected one" or "Chart Dart heap '
              'usage with a GC button".',
              textAlign: TextAlign.center,
              style: Theme.of(context).subtleTextStyle,
            ),
          );
        }
        return GenUiCanvas(
          surfaceController: controller.surfaceController,
          surfaceIds: surfaceIds,
          actionDelegate: controller.actionDelegate,
        );
      },
    );
  }
}

/// Renders the generated surfaces.
class GenUiCanvas extends StatelessWidget {
  const GenUiCanvas({
    super.key,
    required this.surfaceController,
    required this.surfaceIds,
    required this.actionDelegate,
  });

  final SurfaceController surfaceController;
  final List<String> surfaceIds;
  final ActionDelegate actionDelegate;

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        for (final id in surfaceIds)
          Padding(
            padding: const EdgeInsets.only(bottom: defaultSpacing),
            child: RoundedOutlinedBorder(
              child: Padding(
                padding: const EdgeInsets.all(denseSpacing),
                child: Surface(
                  key: ValueKey(id),
                  surfaceContext: surfaceController.contextFor(id),
                  actionDelegate: actionDelegate,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _ChatPanel extends StatefulWidget {
  const _ChatPanel({required this.controller});

  final GenUiController controller;

  @override
  State<_ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends State<_ChatPanel> {
  final _input = TextEditingController();
  final _apiKey = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  void _send() {
    final text = _input.text;
    _input.clear();
    unawaited(widget.controller.sendMessage(text));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = widget.controller;
    return Padding(
      padding: const EdgeInsets.all(denseSpacing),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ValueListenableBuilder<bool>(
            valueListenable: controller.hasAgent,
            builder: (context, hasAgent, _) => hasAgent
                ? Row(
                    children: [
                      const Icon(Icons.check_circle_outline, size: 16),
                      const SizedBox(width: densePadding),
                      const Expanded(child: Text('Gemini agent connected')),
                      TextButton(
                        onPressed: () => unawaited(controller.forgetAgent()),
                        child: const Text('Forget key'),
                      ),
                    ],
                  )
                : TextField(
                    controller: _apiKey,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Gemini API key',
                      helperText:
                          'Saved in plain text in local DevTools preferences.',
                    ),
                    onSubmitted: (key) {
                      _apiKey.clear();
                      controller.configureAgent(key);
                    },
                  ),
          ),
          const SizedBox(height: denseSpacing),
          Expanded(
            child: ValueListenableBuilder<List<GenUiChatEntry>>(
              valueListenable: controller.chatLog,
              builder: (context, log, _) => ListView(
                reverse: true,
                children: [
                  for (final entry in log.reversed)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: densePadding,
                      ),
                      child: SelectableText(
                        entry.text,
                        style: switch (entry.role) {
                          GenUiChatRole.user => theme.boldTextStyle,
                          GenUiChatRole.agent => theme.regularTextStyle,
                          GenUiChatRole.error =>
                            theme.regularTextStyle.copyWith(
                              color: theme.colorScheme.error,
                            ),
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: controller.isWaiting,
            builder: (context, waiting, _) => waiting
                ? const LinearProgressIndicator()
                : const SizedBox(height: 4),
          ),
          TextField(
            controller: _input,
            minLines: 1,
            maxLines: 4,
            decoration: InputDecoration(
              hintText: 'Describe the screen you want',
              suffixIcon: IconButton(
                icon: const Icon(Icons.send),
                onPressed: _send,
              ),
            ),
            onSubmitted: (_) => _send(),
          ),
        ],
      ),
    );
  }
}
