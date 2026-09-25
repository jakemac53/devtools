# jmespath

A pure Dart implementation of [JMESPath](https://jmespath.org), a query
language for JSON.

It implements the full
[JMESPath specification](https://jmespath.org/specification.html), including
all built-in functions, and passes the entire official
[compliance test suite](https://github.com/jmespath/jmespath.test). It has no
dependencies and works on both the Dart VM and the web.

## Usage

```dart
import 'package:jmespath/jmespath.dart';

void main() {
  final data = {
    'people': [
      {'name': 'a', 'age': 30},
      {'name': 'b', 'age': 20},
    ],
  };

  print(search('people[?age > `25`].name', data)); // [a]

  // Compile once, evaluate many times.
  final expression = compile('sort_by(people, &age)[].name');
  print(expression.search(data)); // [b, a]
}
```

Data is represented as plain Dart JSON values: `Map<String, Object?>`, `List`,
`String`, `num`, `bool` and `null` (e.g. the output of `jsonDecode`).

### Custom functions

Additional functions can be provided to `search` or `compile`. Arguments are
type checked against the declared parameter types before the function body is
invoked. Custom functions take precedence over built-in functions.

```dart
final functions = {
  'upper': JmesPathFunction(
    [{JmesPathType.string}],
    (args) => (args[0] as String).toUpperCase(),
  ),
};
search('upper(name)', {'name': 'dash'}, functions: functions); // DASH
```

### Errors

All errors are subclasses of `JmesPathException`, whose `type` corresponds to
the error categories of the specification: `syntax`, `invalid-type`,
`invalid-value`, `invalid-arity` and `unknown-function`. Syntax errors, unknown
functions and arity errors are reported by `compile`; type errors are reported
when the expression is evaluated.

## Testing

```sh
dart test
```

The compliance fixtures are vendored in `test/compliance/`; see the README in
that directory for their source and license.
