// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'dart:async';

import 'package:devtools_app_shared/ui.dart';
import 'package:flutter/material.dart';
import 'package:genui/genui.dart';

import '../../shared/config_specific/copy_to_clipboard/copy_to_clipboard.dart';
import '../../shared/framework/screen.dart';
import '../../shared/globals.dart';
import 'genui_controller.dart';

/// An experimental screen where an agent builds custom DevTools screens out
/// of DevTools components, bound to live data from the connected app.
class GenUiScreen extends Screen {
  GenUiScreen() : super.fromMetaData(ScreenMetaData.genUi);

  static final id = ScreenMetaData.genUi.id;

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

  Future<void> _showLoadDialog(BuildContext context) async {
    final textController = TextEditingController();
    final spec = await showDialog<String>(
      context: context,
      builder: (context) => DevToolsDialog(
        title: const DialogTitleText('Load GenUI spec'),
        content: SizedBox(
          width: 600,
          child: TextField(
            controller: textController,
            maxLines: 16,
            decoration: const InputDecoration(
              hintText: 'Paste a spec copied with "Copy spec"',
            ),
          ),
        ),
        actions: [
          const DialogCancelButton(),
          DialogTextButton(
            onPressed: () => Navigator.of(context).pop(textController.text),
            child: const Text('LOAD'),
          ),
        ],
      ),
    );
    textController.dispose();
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
                      surfaceContext: controller.surfaceController.contextFor(
                        id,
                      ),
                      actionDelegate: controller.actionDelegate,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
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
                        onPressed: () => controller.configureAgent(''),
                        child: const Text('Disconnect'),
                      ),
                    ],
                  )
                : TextField(
                    controller: _apiKey,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Gemini API key',
                      helperText:
                          'Used only in this DevTools session; not stored.',
                    ),
                    onSubmitted: controller.configureAgent,
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
