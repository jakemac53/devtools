// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:genui/genui.dart' show DataContext;

/// Rebuilds with the resolved value of [value], which may be a literal or an
/// A2UI binding such as `{"path": "/requests"}`.
class ResolvedValueBuilder extends StatefulWidget {
  const ResolvedValueBuilder({
    super.key,
    required this.dataContext,
    required this.value,
    required this.builder,
  });

  final DataContext dataContext;
  final Object? value;
  final Widget Function(BuildContext context, Object? value) builder;

  @override
  State<ResolvedValueBuilder> createState() => _ResolvedValueBuilderState();
}

class _ResolvedValueBuilderState extends State<ResolvedValueBuilder> {
  StreamSubscription<Object?>? _subscription;
  Object? _value;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(ResolvedValueBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.dataContext, widget.dataContext) ||
        !jsonEquals(oldWidget.value, widget.value)) {
      _subscribe();
    }
  }

  void _subscribe() {
    unawaited(_subscription?.cancel());
    final value = widget.value;
    if (!isBinding(value)) {
      _value = value;
      _subscription = null;
      return;
    }
    _value = null;
    _subscription = widget.dataContext.resolve(value).listen((v) {
      if (mounted) setState(() => _value = v);
    });
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _value);
}

/// Whether [value] is an A2UI dynamic value (data binding or function call).
bool isBinding(Object? value) =>
    value is Map && (value.containsKey('path') || value.containsKey('call'));

/// Deep equality for JSON-like values.
bool jsonEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is Map || a is List || b is Map || b is List) {
    return jsonEncode(a) == jsonEncode(b);
  }
  return a == b;
}
