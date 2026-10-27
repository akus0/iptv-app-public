import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/services/additional_licenses.dart';

class _Bundle extends CachingAssetBundle {
  final reads = <String, int>{};
  @override
  Future<ByteData> load(String key) async {
    reads.update(key, (n) => n + 1, ifAbsent: () => 1);
    final text = key.endsWith('.json')
        ? jsonEncode({
            'entries': [
              for (final name in ['first', 'second'])
                {
                  'packages': [name],
                  'notice': 'Component notice',
                  'licenceAsset': 'shared-licence.txt',
                },
            ],
          })
        : 'Full licence text';
    return ByteData.sublistView(Uint8List.fromList(utf8.encode(text)));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('native notices load on demand and shared text is read once', () async {
    final bundle = _Bundle();
    final entries = additionalLicenseEntries(bundle);
    expect(bundle.reads, isEmpty);
    final result = await entries.toList();
    expect(result.map((e) => e.packages.single), ['first', 'second']);
    expect(bundle.reads['shared-licence.txt'], 1);
    expect(result.first.paragraphs.map((p) => p.text).join(),
        contains('Full licence text'));
  });

  test('packaged native licences include decoder and repackaged Protobuf',
      () async {
    final entries = await additionalLicenseEntries(rootBundle).toList();
    final packages = entries.expand((e) => e.packages).toList();
    expect(packages, contains('Jellyfin Media3 FFmpeg decoder 1.9.0+1'));
    expect(packages, contains('AndroidX DataStore repackaged Protobuf 1.1.7'));
    expect(packages.any((p) => p.startsWith('androidx.media3:')), isTrue);
    for (final entry in entries) {
      expect(
          entry.paragraphs.map((p) => p.text).join().length, greaterThan(1000));
    }
  });
}
