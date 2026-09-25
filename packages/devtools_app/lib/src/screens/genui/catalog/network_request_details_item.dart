// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'package:flutter/material.dart';
import 'package:genui/genui.dart';
import 'package:json_schema_builder/json_schema_builder.dart';

import '../../network/network_model.dart';
import '../../network/network_request_inspector.dart';
import '../data/ref_store.dart';
import 'bound_value.dart';
import 'layout_safety.dart';

/// Creates the `NetworkRequestDetails` catalog item: a Tier-2 composite that
/// embeds the real Network screen request inspector (overview, headers,
/// request/response bodies, cookies).
CatalogItem networkRequestDetailsCatalogItem(GenUiRefStore refs) => CatalogItem(
  name: 'NetworkRequestDetails',
  dataSchema: S.object(
    description:
        'The DevTools network request inspector for one request. Bind '
        '`request` to a row from the network.requests data source (e.g. '
        'the `selectionPath` of a JsonTable). Rows must keep their `_ref` '
        'field.',
    properties: {
      'request': S.combined(
        description:
            'Data binding to a request row (or its `_ref` string), e.g. '
            '{"path": "/selectedRequest"}.',
        anyOf: [A2uiSchemas.dataBindingSchema(), S.string()],
      ),
      'height': S.number(description: 'Height in pixels (default 400).'),
    },
    required: ['request'],
  ),
  isImplicitlyFlexible: true,
  widgetBuilder: (itemContext) {
    final data = itemContext.data as Map<String, Object?>;
    return BoundedWidth(
      child: ResolvedValueBuilder(
        dataContext: itemContext.dataContext,
        value: data['request'],
        builder: (context, value) => SizedBox(
          height: (data['height'] as num?)?.toDouble() ?? 400,
          child: _NetworkRequestDetails(
            request: refs.resolve<NetworkRequest>(value),
          ),
        ),
      ),
    );
  },
);

class _NetworkRequestDetails extends StatefulWidget {
  const _NetworkRequestDetails({required this.request});

  final NetworkRequest? request;

  @override
  State<_NetworkRequestDetails> createState() => _NetworkRequestDetailsState();
}

class _NetworkRequestDetailsState extends State<_NetworkRequestDetails> {
  late final _request = ValueNotifier<NetworkRequest?>(widget.request);

  @override
  void didUpdateWidget(_NetworkRequestDetails oldWidget) {
    super.didUpdateWidget(oldWidget);
    _request.value = widget.request;
  }

  @override
  void dispose() {
    _request.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      NetworkRequestInspector(request: _request);
}
