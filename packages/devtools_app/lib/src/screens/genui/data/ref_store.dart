// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

/// The key used for opaque object handles in projected JSON rows.
const refKey = '_ref';

/// Hands out opaque string handles (`_ref`s) for typed DevTools objects.
///
/// Data sources project typed models (e.g. `NetworkRequest`) into JSON rows.
/// To let generated UI refer back to the original object - for example to
/// open the real network request inspector for a selected row - each row can
/// carry a `_ref` created by this store. Composite catalog items resolve the
/// `_ref` back into the typed object.
///
/// Objects are held weakly so that handles never keep DevTools data alive.
class GenUiRefStore {
  final _objects = <String, WeakReference<Object>>{};

  /// Returns a handle for [object] of the given [kind] with a stable [id].
  String refFor(Object object, {required String kind, required String id}) {
    final ref = '$kind:$id';
    _objects[ref] = WeakReference(object);
    if (_objects.length > _pruneThreshold) _prune();
    return ref;
  }

  /// Resolves [ref] back to its object, if still alive and of type [T].
  T? resolve<T extends Object>(Object? ref) {
    if (ref is Map) ref = ref[refKey];
    if (ref is! String) return null;
    final object = _objects[ref]?.target;
    return object is T ? object : null;
  }

  static const _pruneThreshold = 10000;

  void _prune() {
    _objects.removeWhere((_, value) => value.target == null);
  }
}
