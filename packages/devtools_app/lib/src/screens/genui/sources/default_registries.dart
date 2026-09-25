// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import '../data/actions.dart';
import '../data/data_source.dart';
import '../data/ref_store.dart';
import 'memory_sources.dart';
import 'network_sources.dart';
import 'vm_sources.dart';

/// The data source and action registries used by the GenUI screen.
///
/// New DevTools domains plug into GenUI by adding their descriptors here.
class GenUiRegistries {
  GenUiRegistries._(this.refs, this.dataSources, this.actions);

  /// Creates registries populated with all built-in DevTools domains.
  factory GenUiRegistries.defaults() {
    final refs = GenUiRefStore();
    final dataSources = DataSourceRegistry(refs: refs)
      ..registerAll(vmDataSources())
      ..registerAll(networkDataSources())
      ..registerAll(memoryDataSources());
    final actions = ActionRegistry(refs: refs)
      ..registerAll(vmActions())
      ..registerAll(networkActions())
      ..registerAll(memoryActions());
    return GenUiRegistries._(refs, dataSources, actions);
  }

  /// Creates empty registries, e.g. for tests.
  factory GenUiRegistries.empty() {
    final refs = GenUiRefStore();
    return GenUiRegistries._(
      refs,
      DataSourceRegistry(refs: refs),
      ActionRegistry(refs: refs),
    );
  }

  final GenUiRefStore refs;
  final DataSourceRegistry dataSources;
  final ActionRegistry actions;
}
