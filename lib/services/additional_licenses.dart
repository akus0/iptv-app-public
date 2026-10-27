import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

bool _registered = false;

/// Register lazily from About; no asset reads or parsing during app startup.
void registerAdditionalLicenses() {
  if (_registered ||
      kIsWeb ||
      defaultTargetPlatform != TargetPlatform.android) {
    return;
  }
  _registered = true;
  LicenseRegistry.addLicense(() => additionalLicenseEntries(rootBundle));
}

/// Native libraries are not all represented by Flutter's Dart-package notices.
Stream<LicenseEntry> additionalLicenseEntries(AssetBundle bundle) async* {
  final manifest = jsonDecode(
    await bundle.loadString('assets/licenses/native-android.json'),
  ) as Map<String, dynamic>;
  final texts = <String, String>{};
  for (final item in manifest['entries'] as List) {
    final entry = item as Map<String, dynamic>;
    final path = entry['licenceAsset'] as String;
    final text = texts[path] ??= await bundle.loadString(path);
    yield LicenseEntryWithLineBreaks(
      (entry['packages'] as List).cast<String>(),
      '${entry['notice']}\n\n$text',
    );
  }
}
