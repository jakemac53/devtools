// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'dart:async';

import 'package:devtools_app_shared/ui.dart';
import 'package:flutter/material.dart';
import 'package:genui/genui.dart';

import '../../../shared/globals.dart';
import '../data/actions.dart';

/// The key in an action event's context that names a data model path to
/// write the action's result to.
const actionResultPathKey = '_resultPath';

/// Signature for asking the user to confirm an app-mutating action.
typedef ConfirmAction =
    Future<bool> Function(BuildContext context, ActionDescriptor action);

/// Runs registered DevTools actions directly from A2UI user events, without a
/// round trip to the agent.
///
/// A2UI buttons dispatch `{"event": {"name": ..., "context": {...}}}`. If
/// `name` is a registered action id, the action runs with `context` as its
/// arguments. Any other event is left for genui to forward to the agent.
class DevToolsActionDelegate implements ActionDelegate {
  DevToolsActionDelegate(this.actions, {ConfirmAction? confirm})
    : _confirm = confirm ?? confirmActionDialog;

  final ActionRegistry actions;
  final ConfirmAction _confirm;

  @override
  bool handleEvent(
    BuildContext context,
    UiEvent event,
    SurfaceContext genUiContext,
    Widget Function(SurfaceDefinition, Catalog, String, DataContext)
    buildWidget,
  ) {
    if (event is! UserActionEvent) return false;
    final action = actions.lookup(event.name);
    if (action == null) return false;
    unawaited(_run(context, action, event.context, genUiContext.dataModel));
    return true;
  }

  Future<void> _run(
    BuildContext context,
    ActionDescriptor action,
    Map<String, Object?> eventContext,
    DataModel dataModel,
  ) async {
    if (action.mutatesApp && !await _confirm(context, action)) return;
    final args = Map.of(eventContext);
    final resultPath = args.remove(actionResultPathKey);
    try {
      final result = await actions.run(action.id, args: args);
      if (resultPath is String && resultPath.isNotEmpty) {
        dataModel.update(DataPath(resultPath), result);
      }
    } catch (e, st) {
      notificationService.pushError(
        'Action ${action.id} failed: $e',
        stackTrace: st.toString(),
        isReportable: false,
      );
    }
  }
}

/// Shows a dialog asking the user to confirm [action].
Future<bool> confirmActionDialog(
  BuildContext context,
  ActionDescriptor action,
) async {
  if (!context.mounted) return false;
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => DevToolsDialog(
      title: const DialogTitleText('Run action?'),
      content: Text(
        'The generated UI wants to run "${action.id}", which changes the '
        'state of the connected app:\n\n${action.description}',
      ),
      actions: [
        DialogTextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('CANCEL'),
        ),
        DialogTextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('RUN'),
        ),
      ],
    ),
  );
  return result ?? false;
}
