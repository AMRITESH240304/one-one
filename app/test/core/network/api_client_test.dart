import 'package:flutter_test/flutter_test.dart';
import 'package:one_one_app/core/network/api_client.dart';

void main() {
  test('decodeJsonObject tolerates non-object backend responses', () {
    expect(decodeJsonObject('{"ok":true}'), {'ok': true});
    expect(decodeJsonObject(''), isEmpty);
    expect(decodeJsonObject('[]'), isEmpty);
    expect(decodeJsonObject('not json'), isEmpty);
  });
}
