// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'dart:async';
import 'dart:convert';

import 'package:a2ui_core/a2ui_core.dart' as core;
import 'package:devtools_app_shared/utils.dart';
import 'package:flutter/foundation.dart';
import 'package:genui/genui.dart';

import '../../shared/framework/screen.dart';
import '../../shared/framework/screen_controllers.dart';
import '../../shared/primitives/storage.dart';
import 'agent/agent_tools.dart';
import 'agent/genkit_transport.dart';
import 'agent/system_prompt.dart';
import 'catalog/action_delegate.dart';
import 'catalog/devtools_catalog.dart';
import 'data/json_utils.dart';
import 'genui_spec.dart';
import 'genui_store.dart';
import 'sources/default_registries.dart';

/// Who authored a [GenUiChatEntry].
enum GenUiChatRole { user, agent, error }

/// A single entry in the GenUI chat log.
class GenUiChatEntry {
  GenUiChatEntry(this.role, this.text);

  final GenUiChatRole role;
  String text;
}

/// Screen controller for the GenUI screen.
///
/// Owns the genui [SurfaceController] (which renders surfaces independently
/// of any agent, so saved specs can be replayed without an API key), and the
/// [Conversation] with the agent, which is only created once an API key has
/// been provided.
class GenUiController extends DevToolsScreenController
    with AutoDisposeControllerMixin {
  GenUiController({GenUiRegistries? registries, GenUiStore? store})
    : registries = registries ?? GenUiRegistries.defaults(),
      _store = store;

  @override
  final screenId = ScreenMetaData.genUi.id;

  final GenUiRegistries registries;

  /// Persists the API key and saved pages. Null when no DevTools [Storage] is
  /// available (e.g. in tests), in which case nothing is persisted.
  GenUiStore? get store => _store ??= switch (globals[Storage]) {
    final Storage storage => GenUiStore(storage),
    _ => null,
  };
  GenUiStore? _store;

  late final Catalog catalog = buildDevToolsCatalog(registries);

  late final surfaceController = SurfaceController(catalogs: [catalog]);

  late final actionDelegate = DevToolsActionDelegate(registries.actions);

  /// The discovery tools exposed to the agent.
  late final List<GenUiAgentTool> agentTools = buildGenUiAgentTools(
    registries,
    surfaceState: surfaceState,
  );

  /// The ids of the surfaces currently shown on the canvas.
  ValueListenable<List<String>> get surfaceIds => _surfaceIds;
  final _surfaceIds = ValueNotifier<List<String>>(const []);

  /// The chat log.
  ValueListenable<List<GenUiChatEntry>> get chatLog => _chatLog;
  final _chatLog = ValueNotifier<List<GenUiChatEntry>>(const []);

  /// Whether the agent is working on a request.
  ValueListenable<bool> get isWaiting => _isWaiting;
  final _isWaiting = ValueNotifier<bool>(false);

  /// Whether an agent is configured (i.e. an API key was provided).
  ValueListenable<bool> get hasAgent => _hasAgent;
  final _hasAgent = ValueNotifier<bool>(false);

  /// Pages the user saved as favorites, sorted by name.
  ValueListenable<List<SavedGenUiPage>> get savedPages => _savedPages;
  final _savedPages = ValueNotifier<List<SavedGenUiPage>>(const []);

  Conversation? _conversation;
  final _conversationSubscriptions = <StreamSubscription<Object?>>[];
  StreamSubscription<Object?>? _surfaceSubscription;

  /// Completes once persisted settings have been loaded.
  Future<void> get persistedStateLoaded => _persistedStateLoaded.future;
  final _persistedStateLoaded = Completer<void>();

  @override
  void init() {
    super.init();
    _surfaceSubscription = surfaceController.surfaceUpdates.listen((_) {
      _surfaceIds.value = surfaceController.activeSurfaceIds.toList();
    });
    unawaited(_loadPersistedState());
  }

  Future<void> _loadPersistedState() async {
    try {
      final store = this.store;
      if (store == null) return;
      final apiKey = await store.readApiKey();
      if (apiKey != null && !_hasAgent.value) {
        configureAgent(apiKey, remember: false);
      }
      _savedPages.value = _sorted(await store.readSavedPages());
    } finally {
      _persistedStateLoaded.complete();
    }
  }

  /// Configures the agent with a Gemini [apiKey], replacing any existing
  /// conversation.
  ///
  /// When [remember] is true the key is persisted, so the agent is configured
  /// automatically the next time DevTools starts.
  void configureAgent(
    String apiKey, {
    String model = defaultGenUiModel,
    bool remember = true,
  }) {
    _disposeConversation();
    apiKey = apiKey.trim();
    if (apiKey.isEmpty) return;
    if (remember) unawaited(store?.writeApiKey(apiKey));
    final transport = GenkitTransport(
      apiKey: apiKey,
      model: model,
      systemPrompt: buildGenUiSystemPrompt(catalog),
      tools: agentTools,
    );
    final conversation = Conversation(
      controller: surfaceController,
      transport: transport,
    );
    _conversation = conversation;
    _conversationSubscriptions.add(
      conversation.events.listen(_onConversationEvent),
    );
    void onStateChanged() {
      _isWaiting.value = conversation.state.value.isWaiting;
    }

    conversation.state.addListener(onStateChanged);
    _removeStateListener = () =>
        conversation.state.removeListener(onStateChanged);
    _hasAgent.value = true;
  }

  /// Disconnects the agent and deletes the stored API key.
  Future<void> forgetAgent() async {
    _disposeConversation();
    await store?.writeApiKey(null);
  }

  /// Saves the current surfaces as a favorite page named [name], replacing
  /// any saved page with the same name.
  Future<void> saveCurrentPage(String name) async {
    name = name.trim();
    if (name.isEmpty) throw ArgumentError.value(name, 'name', 'is empty');
    final page = SavedGenUiPage(
      name: name,
      spec: exportSpec(),
      savedAt: DateTime.now(),
    );
    await _writeSavedPages([
      for (final p in _savedPages.value)
        if (p.name != name) p,
      page,
    ]);
  }

  /// Replaces the current surfaces with the saved [page].
  void loadSavedPage(SavedGenUiPage page) => loadSpec(page.spec);

  /// Deletes the saved page named [name].
  Future<void> deleteSavedPage(String name) => _writeSavedPages([
    for (final p in _savedPages.value)
      if (p.name != name) p,
  ]);

  Future<void> _writeSavedPages(List<SavedGenUiPage> pages) async {
    _savedPages.value = _sorted(pages);
    await store?.writeSavedPages(_savedPages.value);
  }

  static List<SavedGenUiPage> _sorted(List<SavedGenUiPage> pages) =>
      [...pages]
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  VoidCallback? _removeStateListener;

  void _onConversationEvent(ConversationEvent event) {
    switch (event) {
      case ConversationContentReceived(:final text):
        final log = _chatLog.value;
        if (log.isNotEmpty && log.last.role == GenUiChatRole.agent) {
          log.last.text += text;
          _chatLog.value = [...log];
        } else {
          _addChatEntry(GenUiChatEntry(GenUiChatRole.agent, text));
        }
      case ConversationError(:final error):
        _addChatEntry(GenUiChatEntry(GenUiChatRole.error, '$error'));
      case ConversationWaiting():
      case ConversationSurfaceAdded():
      case ConversationComponentsUpdated():
      case ConversationSurfaceRemoved():
        break;
    }
  }

  void _addChatEntry(GenUiChatEntry entry) {
    _chatLog.value = [..._chatLog.value, entry];
  }

  /// Sends [text] from the user to the agent.
  Future<void> sendMessage(String text) async {
    final conversation = _conversation;
    if (text.trim().isEmpty) return;
    _addChatEntry(GenUiChatEntry(GenUiChatRole.user, text));
    if (conversation == null) {
      _addChatEntry(
        GenUiChatEntry(
          GenUiChatRole.error,
          'Enter a Gemini API key to talk to the agent.',
        ),
      );
      return;
    }
    await conversation.sendRequest(ChatMessage.user(text));
  }

  /// Returns a JSON description of the surfaces for the agent: components
  /// and data model contents.
  Object? surfaceState(String? surfaceId) {
    final ids = surfaceId == null
        ? surfaceController.activeSurfaceIds
        : [surfaceId];
    return {
      for (final id in ids)
        id: {
          'components': surfaceController
              .contextFor(id)
              .definition
              .value
              ?.components
              .values
              .map((c) => c.toJson())
              .toList(),
          'dataModel': toJsonSafe(
            surfaceController
                .contextFor(id)
                .dataModel
                .getValue<Object?>(DataPath.root),
          ),
        },
    };
  }

  /// Serializes the current surfaces to a replayable spec.
  String exportSpec() {
    final definitions = [
      for (final id in surfaceController.activeSurfaceIds)
        ?surfaceController.contextFor(id).definition.value,
    ];
    return const JsonEncoder.withIndent(
      '  ',
    ).convert(surfacesToSpec(definitions));
  }

  /// Replaces the current surfaces with those in [spec].
  ///
  /// Throws a [FormatException] if [spec] is invalid.
  void loadSpec(String spec) {
    final messages = parseSpec(spec);
    clearSurfaces();
    messages.forEach(surfaceController.handleMessage);
  }

  /// Removes all surfaces.
  void clearSurfaces() {
    for (final id in surfaceController.activeSurfaceIds.toList()) {
      surfaceController.handleMessage(core.DeleteSurfaceMessage(surfaceId: id));
    }
  }

  void _disposeConversation() {
    for (final s in _conversationSubscriptions) {
      unawaited(s.cancel());
    }
    _conversationSubscriptions.clear();
    _removeStateListener?.call();
    _removeStateListener = null;
    final conversation = _conversation;
    _conversation = null;
    conversation?.transport.dispose();
    conversation?.dispose();
    _hasAgent.value = false;
    _isWaiting.value = false;
  }

  @override
  void dispose() {
    _disposeConversation();
    unawaited(_surfaceSubscription?.cancel());
    surfaceController.dispose();
    _surfaceIds.dispose();
    _chatLog.dispose();
    _isWaiting.dispose();
    _hasAgent.dispose();
    _savedPages.dispose();
    super.dispose();
  }
}
