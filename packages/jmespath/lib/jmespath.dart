// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

/// A pure Dart implementation of the JMESPath query language for JSON.
///
/// See https://jmespath.org/specification.html.
library;

export 'src/exceptions.dart';
export 'src/functions.dart'
    show
        ExpressionReference,
        JmesPathFunction,
        JmesPathFunctionBody,
        JmesPathType;
export 'src/jmespath.dart';
export 'src/values.dart' show isTruthy, jsonEquals;
