import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nox_iptv/services/app_update_service.dart';

void main() {
  test('preview never requests an upstream update', () async {
    var requested = false;
    await http.runWithClient(() async {
      expect(await AppUpdateService().checkForUpdate(), isNull);
    },
        () => MockClient((_) async {
              requested = true;
              return http.Response('{}', 200);
            }));
    expect(requested, isFalse);
  });
}
