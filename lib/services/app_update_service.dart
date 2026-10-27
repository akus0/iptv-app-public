import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/l10n.dart';
import '../utils/constants.dart';

/// A GitHub release newer than what's currently installed.
class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.releaseNotes,
    required this.downloadUrl,
    required this.apkSizeBytes,
  });

  /// The release's tag name (e.g. "3.19.1") — same scheme as the app's own
  /// version, so it's directly comparable via [_isDifferent].
  final String version;
  final String releaseNotes;

  /// The matching asset's direct download URL — an `.apk` on Android, a
  /// `.zip` on Windows (see [AppUpdateService.checkForUpdate]'s own doc
  /// comment for why Windows only ever opens this in a browser instead of
  /// downloading/installing it the way Android does).
  final String downloadUrl;
  final int apkSizeBytes;
}

/// Checks GitHub for a newer release, downloads it, and hands it to
/// Android's own package installer — there's no Play Store auto-update for
/// a sideloaded app, so this is the in-app replacement (Settings > Check
/// for Updates). See MainActivity.kt's doc comment for the native half
/// (install permission check + the actual install intent, which needs a
/// FileProvider — no pure-Dart/Flutter-plugin way to trigger an APK
/// install exists).
class AppUpdateService {
  static const _channel = MethodChannel('com.nox.nox_iptv/app_update');

  /// Public, unauthenticated GitHub API — fine for a public repo at this
  /// call volume (a user tapping "Check for Updates" occasionally), no
  /// token needed and none should be embedded in a distributed APK anyway.
  static const _apiUrl =
      'https://api.github.com/repos/NoXqc/VesperTV/releases/latest';

  /// Null if already up to date, the request fails, or the release has no
  /// `.apk` asset attached (shouldn't happen for a real release, but a
  /// malformed/source-only one shouldn't crash the check).
  Future<UpdateInfo?> checkForUpdate() async {
    if (!AppConstants.updatesEnabled) return null;
    final response = await http.get(
      Uri.parse(_apiUrl),
      headers: {
        'Accept': 'application/vnd.github+json',
        // Request a fresh release response to avoid intermediary caches returning an unusable
        // conditional 304.
        'Cache-Control': 'no-cache',
        'Pragma': 'no-cache',
      },
    ).timeout(const Duration(seconds: 15));
    if (response.statusCode == 304) {
      // Treat a bodyless 304 as no new release information rather than a connection failure.
      return null;
    }
    if (response.statusCode != 200) {
      // A bare "HTTP 403" reads as a permissions problem, but the actual
      // cause here is almost always GitHub's unauthenticated API rate
      // limit (60 requests/hour, shared by *every* device on the same
      // home network's public IP) — easy to hit when there's more than
      // one box/phone on the same network each tapping this button.
      // `X-RateLimit-Remaining: 0` distinguishes that specifically so the
      // message actually says what's wrong instead of leaving it a
      // mystery, e.g. "check again in the browser and it just works" the
      // next hour once the window resets.
      if (response.statusCode == 403 &&
          response.headers['x-ratelimit-remaining'] == '0') {
        final resetHeader = response.headers['x-ratelimit-reset'];
        final resetSeconds = int.tryParse(resetHeader ?? '');
        final waitMinutes = resetSeconds == null
            ? null
            : ((DateTime.fromMillisecondsSinceEpoch(resetSeconds * 1000)
                        .difference(DateTime.now())
                        .inSeconds) /
                    60)
                .ceil();
        throw Exception(waitMinutes != null && waitMinutes > 0
            ? trPlural(
                waitMinutes,
                'GitHub is temporarily rate-limiting update checks from this network — try again in about {n} minute.',
                'GitHub is temporarily rate-limiting update checks from this network — try again in about {n} minutes.')
            : tr(
                'GitHub is temporarily rate-limiting update checks from this network — try again shortly.'));
      }
      throw Exception('GitHub returned HTTP ${response.statusCode}');
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final latestVersion = (decoded['tag_name'] as String?)?.trim();
    if (latestVersion == null || latestVersion.isEmpty) return null;

    final packageInfo = await PackageInfo.fromPlatform();
    if (!_isDifferent(latestVersion, packageInfo.version)) return null;

    // Windows has no package-installer equivalent to hand an `.apk` to —
    // its release asset is a plain `.zip` of the built Release folder
    // instead (see CheckUpdatesScreen's own doc comment for the simpler
    // "open it in a browser" flow that's all Windows actually needs).
    final extension = Platform.isWindows ? '.zip' : '.apk';
    final assets = (decoded['assets'] as List?) ?? const [];
    final matchingAsset = assets.cast<Map<String, dynamic>>().firstWhere(
          (a) =>
              (a['name'] as String?)?.toLowerCase().endsWith(extension) ??
              false,
          orElse: () => const {},
        );
    final downloadUrl = matchingAsset['browser_download_url'] as String?;
    if (downloadUrl == null) return null;

    return UpdateInfo(
      version: latestVersion,
      releaseNotes: (decoded['body'] as String?)?.trim() ?? '',
      downloadUrl: downloadUrl,
      apkSizeBytes: (matchingAsset['size'] as int?) ?? 0,
    );
  }

  /// Compare numeric version segments, treating absent segments as zero.
  bool _isDifferent(String remote, String local) {
    final r = _versionParts(remote);
    final l = _versionParts(local);
    for (var i = 0; i < r.length || i < l.length; i++) {
      final rPart = i < r.length ? r[i] : 0;
      final lPart = i < l.length ? l[i] : 0;
      if (rPart != lPart) return true;
    }
    return false;
  }

  /// Strip an optional leading v before comparing numeric version segments.
  List<int> _versionParts(String version) {
    final stripped = version.startsWith('v') ? version.substring(1) : version;
    return stripped.split('.').map((s) => int.tryParse(s) ?? 0).toList();
  }

  /// Downloads to the app's own cache directory (matching the
  /// FileProvider path config that grants the installer read access to
  /// exactly this one file, nothing broader) — overwrites any previous
  /// download of the same name rather than accumulating old ones.
  Future<File> downloadUpdate(String downloadUrl,
      {void Function(double fraction)? onProgress}) async {
    final request = http.Request('GET', Uri.parse(downloadUrl));
    final response = await http.Client().send(request);
    if (response.statusCode != 200) {
      throw Exception('Download failed: HTTP ${response.statusCode}');
    }

    final total = response.contentLength ?? 0;
    var received = 0;
    final dir = await getTemporaryDirectory();
    final file = File(p.join(dir.path, 'noxplayer_update.apk'));
    final sink = file.openWrite();

    await response.stream.map((chunk) {
      received += chunk.length;
      if (total > 0) onProgress?.call(received / total);
      return chunk;
    }).pipe(sink);
    await sink.close();

    return file;
  }

  /// Android 8+ only — earlier versions have no per-app "unknown sources"
  /// gate at all. Always true there, so callers don't need to branch on
  /// OS version themselves.
  Future<bool> canRequestInstalls() async {
    final result = await _channel.invokeMethod<bool>('canRequestInstalls');
    return result ?? false;
  }

  /// Opens the system settings screen where the user grants this app
  /// "install unknown apps" access — Android requires this be a real user
  /// action from Settings, no app (this one included) can grant it to
  /// itself. No-op on pre-Android-8, where it isn't needed.
  Future<void> requestInstallPermission() =>
      _channel.invokeMethod('requestInstallPermission');

  /// Hands the downloaded file to the system package installer — this is
  /// the point where the OS's own install-confirmation UI takes over;
  /// nothing past this call can be automated further from inside the app.
  Future<void> installApk(String filePath) =>
      _channel.invokeMethod('installApk', {'filePath': filePath});

  /// Windows' whole update flow — no `MainActivity.kt`-style native
  /// installer channel exists for it (nothing in this repo builds a
  /// signed Windows installer at all yet, just a plain Release folder),
  /// so there's nothing to silently download-and-install the way Android
  /// does. Opening the asset's direct URL in the system browser and
  /// letting the user unzip/run it themselves is the entire mechanism.
  Future<bool> openInBrowser(String url) =>
      launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
}
