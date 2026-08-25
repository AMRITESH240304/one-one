import 'package:flutter_test/flutter_test.dart';

import 'package:one_one_app/one_one.dart';

void main() {
  test('mutableMapOf copies const and unmodifiable maps so writes succeed', () {
    const original = <String, Object>{'a': 1};
    final copy = mutableMapOf(original);
    copy['b'] = 2;
    expect(copy, {'a': 1, 'b': 2});
    expect(original.containsKey('b'), isFalse);

    final fromUnmodifiable = mutableMapOf(Map<String, Object>.unmodifiable({}));
    fromUnmodifiable['k'] = 'v';
    expect(fromUnmodifiable['k'], 'v');
  });

  test('service status Remote Config defaults are writable', () {
    final defaults = serviceStatusRemoteDefaults();
    defaults['service_status'] = 'maintenance';
    expect(defaults['service_status'], 'maintenance');
  });
}
