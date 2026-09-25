// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'dart:convert';

import 'package:logging/logging.dart';

import '../../shared/primitives/storage.dart';

final _log = Logger('genui_store');

/// A generated page the user saved as a favorite.
class SavedGenUiPage {
  const SavedGenUiPage({
    required this.name,
    required this.spec,
    required this.savedAt,
  });

  factory SavedGenUiPage.fromJson(Map<String, Object?> json) => SavedGenUiPage(
    name: json['name'] as String,
    spec: json['spec'] as String,
    savedAt: DateTime.fromMillisecondsSinceEpoch(json['savedAt'] as int),
  );

  final String name;

  /// A replayable spec, as produced by `GenUiController.exportSpec`.
  final String spec;

  final DateTime savedAt;

  Map<String, Object?> toJson() => {
    'name': name,
    'spec': spec,
    'savedAt': savedAt.millisecondsSinceEpoch,
  };
}

/// Persists GenUI settings (the agent API key and saved pages) using the
/// DevTools [Storage] (the same key/value store used for DevTools
/// preferences: browser local storage on web, `~/.flutter-devtools/.devtools`
/// on desktop or when served by the DevTools server).
///
/// Values are stored in plain text.
class GenUiStore {
  GenUiStore(this._storage);

  final Storage _storage;

  static const apiKeyKey = 'genui.apiKey';
  static const savedPagesKey = 'genui.savedPages';

  Future<String?> readApiKey() async {
    final value = await _storage.getValue(apiKeyKey);
    return value == null || value.isEmpty ? null : value;
  }

  /// Stores [apiKey], or clears it when null.
  Future<void> writeApiKey(String? apiKey) =>
      _storage.setValue(apiKeyKey, apiKey ?? '');

  Future<List<SavedGenUiPage>> readSavedPages() async {
    final value = await _storage.getValue(savedPagesKey);
    if (value == null || value.isEmpty) return const [];
    try {
      return [
        for (final page in jsonDecode(value) as List)
          SavedGenUiPage.fromJson((page as Map).cast<String, Object?>()),
      ];
    } catch (e, st) {
      _log.warning('Ignoring invalid saved GenUI pages', e, st);
      return const [];
    }
  }

  Future<void> writeSavedPages(List<SavedGenUiPage> pages) => _storage.setValue(
    savedPagesKey,
    jsonEncode([for (final page in pages) page.toJson()]),
  );
}
