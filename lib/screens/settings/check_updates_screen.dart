import 'dart:io';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../services/app_update_service.dart';
import '../../utils/tv_theme.dart';
import '../../widgets/mode_button.dart';
import '../../widgets/settings_scaffold.dart';
import '../../l10n/l10n.dart';

/// Settings > Check for Updates — the in-app replacement for a Play Store
/// auto-update, since this is a sideloaded app with no store distribution.
/// See AppUpdateService's doc comment for the full check/download/install
/// mechanism and its one hard limit: Android itself, not this app, decides
/// whether the actual install step needs a fresh user tap on its own
/// confirmation dialog — nothing past handing the APK to the installer can
/// be automated further.
class CheckUpdatesScreen extends StatefulWidget {
  const CheckUpdatesScreen({super.key, this.startWith});

  /// From the launch update popup's "Update": skip the check and start
  /// the download (Android) / open the download page (Windows) at once.
  final UpdateInfo? startWith;

  @override
  State<CheckUpdatesScreen> createState() => _CheckUpdatesScreenState();
}

enum _Status {
  idle,
  checking,
  upToDate,
  updateAvailable,
  downloading,
  readyToInstall,
  error
}

class _CheckUpdatesScreenState extends State<CheckUpdatesScreen> {
  final _updateService = AppUpdateService();
  String _currentVersion = '';
  _Status _status = _Status.idle;
  UpdateInfo? _update;
  double _downloadProgress = 0;
  String? _errorMessage;
  String? _downloadedApkPath;

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((info) {
      if (mounted) setState(() => _currentVersion = info.version);
    });
    final start = widget.startWith;
    if (start != null) {
      _update = start;
      _status = _Status.updateAvailable;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Platform.isWindows ? _openWindowsDownload() : _download();
      });
    }
  }

  Future<void> _check() async {
    setState(() {
      _status = _Status.checking;
      _errorMessage = null;
    });
    try {
      final update = await _updateService.checkForUpdate();
      if (!mounted) return;
      setState(() {
        _update = update;
        _status = update == null ? _Status.upToDate : _Status.updateAvailable;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = _Status.error;
        _errorMessage = e.toString();
      });
    }
  }

  /// Windows' entire update flow — see AppUpdateService.openInBrowser's
  /// doc comment for why there's no download/install state machine to
  /// drive here the way Android's [_download]/[_install] do: nothing past
  /// opening the browser can be automated on this platform at all yet.
  Future<void> _openWindowsDownload() async {
    final update = _update;
    if (update == null) return;
    final opened = await _updateService.openInBrowser(update.downloadUrl);
    if (!mounted || opened) return;
    setState(() {
      _status = _Status.error;
      _errorMessage = tr('Couldn\'t open the download link.');
    });
  }

  Future<void> _download() async {
    final update = _update;
    if (update == null) return;
    setState(() {
      _status = _Status.downloading;
      _downloadProgress = 0;
    });
    try {
      final file = await _updateService.downloadUpdate(
        update.downloadUrl,
        onProgress: (fraction) {
          if (mounted) setState(() => _downloadProgress = fraction);
        },
      );
      if (!mounted) return;
      setState(() {
        _downloadedApkPath = file.path;
        _status = _Status.readyToInstall;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = _Status.error;
        _errorMessage = e.toString();
      });
    }
  }

  Future<void> _install() async {
    final path = _downloadedApkPath;
    if (path == null) return;
    final canInstall = await _updateService.canRequestInstalls();
    if (!canInstall) {
      if (!mounted) return;
      final proceed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(tr('Allow installing updates')),
          content: Text(
            tr('Android needs one-time permission for iptv-app to install an update it downloaded. The next screen is Android\'s own settings — turn the toggle on, then come back here and press Install again.'),
          ),
          // Plain TextButton/FilledButton left which one has D-pad focus
          // ambiguous — FilledButton's permanent solid fill looks the
          // same whether it's actually focused or not. ModeButton is this
          // app's established fix elsewhere for exactly this.
          actions: [
            ModeButton(
              label: tr('Cancel'),
              selected: false,
              onTap: () => Navigator.of(context).pop(false),
            ),
            ModeButton(
              label: tr('Open Settings'),
              selected: false,
              onTap: () => Navigator.of(context).pop(true),
            ),
          ],
        ),
      );
      if (proceed == true) await _updateService.requestInstallPermission();
      return;
    }
    await _updateService.installApk(path);
  }

  @override
  Widget build(BuildContext context) {
    return withTvThemeIfNeeded(
        context,
        (context) => SettingsScaffold(
              title: tr('Check for Updates'),
              body: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(
                    _currentVersion.isEmpty
                        ? tr('Current version: —')
                        : tr('Current version: {currentVersion}',
                            {'currentVersion': _currentVersion}),
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 16),
                  ..._buildStatusContent(context),
                ],
              ),
            ));
  }

  List<Widget> _buildStatusContent(BuildContext context) {
    switch (_status) {
      case _Status.idle:
        return [
          OutlinedButton.icon(
            icon: const Icon(Icons.system_update),
            label: Text(tr('Check for Updates')),
            onPressed: _check,
          ),
        ];
      case _Status.checking:
        return [
          Row(
            children: [
              const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 12),
              Text(tr('Checking...')),
            ],
          ),
        ];
      case _Status.upToDate:
        return [
          Text(tr('You\'re on the latest version.')),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: _check, child: Text(tr('Check Again'))),
        ];
      case _Status.updateAvailable:
        final update = _update!;
        return [
          Text(
            tr('Version {version} is available', {'version': update.version}),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (update.releaseNotes.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(update.releaseNotes,
                style: Theme.of(context).textTheme.bodySmall),
          ],
          const SizedBox(height: 16),
          if (Platform.isWindows) ...[
            FilledButton.icon(
              icon: const Icon(Icons.open_in_browser),
              label: Text(tr('Open Download Page')),
              onPressed: _openWindowsDownload,
            ),
            const SizedBox(height: 4),
            Text(
              tr('Opens in your browser — unzip the download and run the application to update, replacing the old folder.'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ] else
            FilledButton.icon(
              icon: const Icon(Icons.download),
              label: Text(tr('Download & Install')),
              onPressed: _download,
            ),
        ];
      case _Status.downloading:
        return [
          Text(tr('Downloading update... {p}%',
              {'p': (_downloadProgress * 100).toStringAsFixed(0)})),
          const SizedBox(height: 12),
          LinearProgressIndicator(
              value: _downloadProgress > 0 ? _downloadProgress : null),
        ];
      case _Status.readyToInstall:
        return [
          Text(tr('Download complete.')),
          const SizedBox(height: 16),
          FilledButton.icon(
            icon: const Icon(Icons.install_mobile),
            label: Text(tr('Install')),
            onPressed: _install,
          ),
          const SizedBox(height: 4),
          Text(
            tr('Android will ask you to confirm the install — that\'s normal, not every app can skip it.'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ];
      case _Status.error:
        return [
          Text(
              tr('Something went wrong: {p}',
                  {'p': _errorMessage ?? tr('unknown error')}),
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: _check, child: Text(tr('Try Again'))),
        ];
    }
  }
}
