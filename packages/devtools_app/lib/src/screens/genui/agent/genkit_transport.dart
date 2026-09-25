// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'dart:async';

import 'package:a2ui_core/a2ui_core.dart' as core;
import 'package:genkit/genkit.dart' as gk;
import 'package:genkit_google_genai/genkit_google_genai.dart';
import 'package:genui/genui.dart';
import 'package:schemantic/schemantic.dart';

import 'agent_tools.dart';

/// The default Gemini model used by the GenUI screen.
const defaultGenUiModel = 'gemini-flash-latest';

/// A genui [Transport] that talks to Gemini directly from DevTools using
/// Genkit and a user-provided API key.
///
/// This is the prototype "embedded LLM" host. The rest of the GenUI screen
/// only depends on the [Transport] interface, so the same UI can be driven by
/// other hosts - notably an MCP App, where the agent lives in the MCP client
/// and [GenUiAgentTool]s are exposed as MCP tools instead of Genkit tools.
class GenkitTransport implements Transport {
  GenkitTransport({
    required String apiKey,
    required String systemPrompt,
    required List<GenUiAgentTool> tools,
    String model = defaultGenUiModel,
    this.maxTurns = 12,
  }) : _systemMessage = gk.Message(
         role: gk.Role.system,
         content: [gk.TextPart(text: systemPrompt)],
       ),
       _model = googleAI.gemini(model),
       _ai = gk.Genkit(plugins: [googleAI(apiKey: apiKey)], isDevEnv: false) {
    _tools = [for (final tool in tools) _toGenkitTool(tool)];
  }

  final gk.Genkit _ai;
  final gk.ModelRef<GeminiOptions> _model;
  final gk.Message _systemMessage;
  late final List<gk.Tool> _tools;

  /// The maximum number of model turns (tool call round trips) per request.
  final int maxTurns;

  final _adapter = A2uiTransportAdapter();
  final _history = <gk.Message>[];
  Future<void> _pending = Future.value();

  @override
  Stream<String> get incomingText => _adapter.incomingText;

  @override
  Stream<core.A2uiMessage> get incomingMessages => _adapter.incomingMessages;

  @override
  Future<void> sendRequest(ChatMessage message) {
    // Serialize requests so that the history stays consistent.
    final result = _pending.then((_) => _send(message));
    _pending = result.catchError((_) {});
    return result;
  }

  Future<void> _send(ChatMessage message) async {
    final text = chatMessageToPrompt(message);
    if (text.isEmpty) return;
    _history.add(
      gk.Message(
        role: gk.Role.user,
        content: [gk.TextPart(text: text)],
      ),
    );
    final response = await _ai.generate(
      model: _model,
      messages: [_systemMessage, ..._history],
      tools: _tools,
      maxTurns: maxTurns,
      onChunk: (chunk) {
        final chunkText = chunk.text;
        if (chunkText.isNotEmpty) _adapter.addChunk(chunkText);
      },
    );
    _history
      ..clear()
      ..addAll(response.messages.where((m) => m.role != gk.Role.system));
  }

  /// Clears the conversation history.
  void reset() => _history.clear();

  @override
  void dispose() {
    _adapter.dispose();
  }

  static gk.Tool<Map<String, dynamic>, Object?> _toGenkitTool(
    GenUiAgentTool tool,
  ) {
    return gk.Tool<Map<String, dynamic>, Object?>(
      name: tool.name,
      description: tool.description,
      inputSchema: SchemanticType.from<Map<String, dynamic>>(
        jsonSchema: tool.inputJsonSchema,
        parse: (json) =>
            json is Map ? json.cast<String, dynamic>() : <String, dynamic>{},
      ),
      fn: (input, _) async => gk.ToolResult.response(await tool.call(input)),
    );
  }
}

/// Flattens a genui [ChatMessage] (text plus UI interaction parts) into a
/// single prompt string.
String chatMessageToPrompt(ChatMessage message) {
  return [
    if (message.text.trim().isNotEmpty) message.text,
    for (final part in message.parts.uiInteractionParts)
      'UI event: ${part.interaction}',
  ].join('\n');
}
