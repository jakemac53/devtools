// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

/// Messages that GenUI posts to the window embedding DevTools, if any.
///
/// Hosts that show DevTools in an iframe (such as the DevTools GenUI
/// Antigravity plugin, see `docs/genui/plugin`) listen for these to tell an
/// external agent what is happening in DevTools right away, instead of
/// waiting for the agent to poll the `genUi` VM service method.
///
/// Every message is a map with a `type` key, one of the message type
/// constants below.
library;

import 'package:flutter/foundation.dart';

import '../../shared/config_specific/post_message/post_message.dart';

/// The type of the message sent once the `genUi` VM service method is
/// registered with the connected app, so an external agent can start calling
/// it.
///
/// The `method` key holds the full, namespaced method name to call (e.g.
/// `s1.genUi`).
const genUiReadyMessageType = 'devtools.genui.ready';

/// The type of the message sent for each user interaction that is buffered
/// for an external agent (see `GenUiController.takeExternalEvents`).
///
/// The `event` key holds the interaction.
const genUiEventMessageType = 'devtools.genui.event';

/// Posts a message of [type] with [data] to the window embedding DevTools.
///
/// Does nothing when DevTools is not running on the web.
void postGenUiEmbedderMessage(String type, Map<String, Object?> data) {
  if (!kIsWeb) return;
  postMessage({'type': type, ...data}, '*');
}
