// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'dart:convert';

import 'package:devtools_app/src/screens/genui/catalog/devtools_catalog.dart';
import 'package:devtools_app/src/screens/genui/genui_controller.dart';
import 'package:devtools_app/src/screens/genui/genui_store.dart';
import 'package:devtools_app/src/screens/genui/sources/default_registries.dart';
import 'package:devtools_app/src/shared/primitives/storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryStorage implements Storage {
  final values = <String, String>{};

  @override
  Future<String?> getValue(String key) async => values[key];

  @override
  Future<void> setValue(String key, String value) async => values[key] = value;
}

String _spec(String text) => jsonEncode([
  {
    'version': 'v0.9',
    'createSurface': {'surfaceId': 'main', 'catalogId': devToolsCatalogId},
  },
  {
    'version': 'v0.9',
    'updateComponents': {
      'surfaceId': 'main',
      'components': [
        {'id': 'root', 'component': 'Text', 'text': text},
      ],
    },
  },
]);

void main() {
  late _MemoryStorage storage;

  setUp(() => storage = _MemoryStorage());

  group('GenUiStore', () {
    test('stores and clears the API key', () async {
      final store = GenUiStore(storage);
      expect(await store.readApiKey(), isNull);
      await store.writeApiKey('secret');
      expect(await store.readApiKey(), 'secret');
      await store.writeApiKey(null);
      expect(await store.readApiKey(), isNull);
    });

    test('round trips saved pages and ignores corrupt data', () async {
      final store = GenUiStore(storage);
      final savedAt = DateTime.fromMillisecondsSinceEpoch(1000);
      await store.writeSavedPages([
        SavedGenUiPage(name: 'Memory', spec: '[]', savedAt: savedAt),
      ]);
      final pages = await store.readSavedPages();
      expect(pages.single.name, 'Memory');
      expect(pages.single.spec, '[]');
      expect(pages.single.savedAt, savedAt);

      storage.values[GenUiStore.savedPagesKey] = 'not json';
      expect(await store.readSavedPages(), isEmpty);
    });
  });

  group('GenUiController saved pages', () {
    GenUiController createController() {
      final controller = GenUiController(
        registries: GenUiRegistries.empty(),
        store: GenUiStore(storage),
      )..init();
      addTearDown(controller.dispose);
      return controller;
    }

    test('saves, reloads, loads and deletes pages', () async {
      final controller = createController();
      await controller.persistedStateLoaded;
      controller.loadSpec(_spec('first'));
      await controller.saveCurrentPage(' Zeta ');
      controller.loadSpec(_spec('second'));
      await controller.saveCurrentPage('alpha');
      expect(controller.savedPages.value.map((p) => p.name), ['alpha', 'Zeta']);

      // Saving with an existing name replaces the page.
      await controller.saveCurrentPage('alpha');
      expect(controller.savedPages.value, hasLength(2));

      // A new controller (e.g. after restarting DevTools) sees the pages.
      final restarted = createController();
      await restarted.persistedStateLoaded;
      final zeta = restarted.savedPages.value.last;
      expect(zeta.name, 'Zeta');
      restarted.loadSavedPage(zeta);
      final components = restarted.surfaceController
          .contextFor('main')
          .definition
          .value!
          .components;
      expect(components['root']!.properties['text'], 'first');

      await restarted.deleteSavedPage('Zeta');
      expect(restarted.savedPages.value.map((p) => p.name), ['alpha']);
      expect((await GenUiStore(storage).readSavedPages()).map((p) => p.name), [
        'alpha',
      ]);
    });

    test('forgetAgent clears the stored API key', () async {
      await GenUiStore(storage).writeApiKey('secret');
      final controller = GenUiController(
        registries: GenUiRegistries.empty(),
        store: GenUiStore(storage),
      );
      addTearDown(controller.dispose);
      await controller.forgetAgent();
      expect(await GenUiStore(storage).readApiKey(), isNull);
      expect(controller.hasAgent.value, isFalse);
    });
  });
}
