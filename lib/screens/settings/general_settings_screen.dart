import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/app_preferences.dart';
import '../../services/playback_service.dart';
import '../../services/storage_service.dart';
import '../../utils/tv_theme.dart';
import '../../widgets/live_resume_hint.dart';
import '../../widgets/section_label.dart';
import '../../widgets/settings_scaffold.dart';
import '../../widgets/settings_section.dart';
import '../../widgets/tv_menu_tile.dart';
import '../../widgets/tv_switch_list_tile.dart';
import '../../l10n/l10n.dart';

/// Small behaviour switches that don't belong to one feature's own screen —
/// a home for future ones too (planned candidates: start-on tab, default
/// picture fit, preferred audio language, confirm on exit).
/// Multiview is Android only (Windows has its own Multiview without the
/// tip); everything else is shown on every platform. Startup and Tabs are
/// device-wide, not per viewer profile.
///
/// No custom D-pad handling — see SettingsMenuScreen's doc comment.
class GeneralSettingsScreen extends StatefulWidget {
  const GeneralSettingsScreen({super.key});

  @override
  State<GeneralSettingsScreen> createState() => _GeneralSettingsScreenState();
}

class _GeneralSettingsScreenState extends State<GeneralSettingsScreen> {
  late final StorageService _storage = context.read<StorageService>();
  late bool _resumeAtStartup = _storage.getResumeLastChannelAtStartup();
  late bool _resumeInGuide =
      !_resumeAtStartup && _storage.getResumeLastChannelInGuide();
  late bool _showResumePill = _storage.getShowResumePill();

  /// Cancel is focused by default so a stray Select can't wipe anything.
  Future<bool> _confirm(String title, String message) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(tr('Clear')),
          ),
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(tr('Cancel')),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _clearSearchAndChannelHistory() async {
    if (!await _confirm(tr('Clear search & channel history?'),
        tr('Removes your recent searches and the History list of live channels.'))) {
      return;
    }
    if (!mounted) return;
    final playback = context.read<PlaybackService>();
    await _storage.clearRecentSearches();
    await playback.clearRecentlyPlayed(live: true);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('Search and channel history cleared.'))));
  }

  /// Language settings in the picker, in order. A new language = one entry
  /// here (native name, never translated) plus its dictionary in l10n.
  static const _languages = [
    ('auto', ''),
    ('en', 'English'),
    ('fr', 'Français'),
    ('es', 'Español'),
    ('it', 'Italiano'),
  ];

  String _languageLabel(String setting) => setting == 'auto'
      ? tr('Automatic')
      : _languages.firstWhere((l) => l.$1 == setting).$2;

  /// One row + a short pop-up list (current one focused) instead of a
  /// button per language, so the row stays small as languages are added.
  Future<void> _pickLanguage() async {
    final picked = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text(tr('Language')),
        children: [
          for (final (code, _) in _languages)
            TvMenuTile(
              icon: Icons.translate,
              autofocus: code == L10n.setting,
              title: _languageLabel(code),
              subtitle:
                  code == 'auto' ? tr('Follows the device language') : null,
              trailing: code == L10n.setting
                  ? Icon(Icons.check,
                      color: Theme.of(dialogContext).colorScheme.primary)
                  : null,
              onTap: () => Navigator.of(dialogContext).pop(code),
            ),
        ],
      ),
    );
    if (picked != null) await _setLanguage(picked);
  }

  /// Back to home first: main.dart remounts home on a language change, but
  /// routes already pushed above it would keep their old-language strings.
  Future<void> _setLanguage(String value) async {
    if (value == L10n.setting || !mounted) return;
    final prefs = context.read<AppPreferences>();
    Navigator.of(context).popUntil((route) => route.isFirst);
    await prefs.setLanguage(value);
  }

  String get _startupLabel => _resumeAtStartup
      ? 'Full screen'
      : _resumeInGuide
          ? 'In the preview'
          : 'Do not play automatically';
  Future<void> _pickStartup() async {
    final selected = _resumeAtStartup
        ? 2
        : _resumeInGuide
            ? 1
            : 0;
    final choice = await showDialog<int>(
        context: context,
        builder: (dialogContext) => AlertDialog(
              scrollable: true,
              title: Text(tr('Playback at startup')),
              contentPadding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
              content: SizedBox(
                  width: 360,
                  child: SettingsScope(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                    for (final (index, label, icon) in [
                      (
                        0,
                        'Do not play automatically',
                        Icons.pause_circle_outline
                      ),
                      (1, 'In the preview', Icons.picture_in_picture_alt),
                      (2, 'Full screen', Icons.fullscreen),
                    ])
                      TvMenuTile(
                          icon: icon,
                          title: tr(label),
                          autofocus: selected == index,
                          trailing: selected == index
                              ? const Icon(Icons.check, size: 20)
                              : const SizedBox.shrink(),
                          onTap: () => Navigator.pop(dialogContext, index)),
                  ]))),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: Text(tr('Cancel')))
              ],
            ));
    if (choice == null || !mounted) return;
    setState(() {
      _resumeAtStartup = choice == 2;
      _resumeInGuide = choice == 1;
    });
    await _storage.setResumeLastChannelAtStartup(choice == 2);
    await _storage.setResumeLastChannelInGuide(choice == 1);
  }

  @override
  Widget build(BuildContext context) {
    return withTvThemeIfNeeded(
        context,
        (context) => SettingsScaffold(
              title: tr('Playback & preferences'),
              body: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  SectionLabel(tr('Language')),
                  const SizedBox(height: 4),
                  TvMenuTile(
                    icon: Icons.translate,
                    title: _languageLabel(L10n.setting),
                    subtitle: L10n.setting == 'auto'
                        ? tr('Follows the device language')
                        : null,
                    onTap: _pickLanguage,
                  ),
                  TvSwitchListTile(
                    title: Text(tr('24-hour clock')),
                    subtitle: Text(context.watch<AppPreferences>().use24h
                        ? tr('Times show as 21:30')
                        : tr('Times show as 9:30 PM')),
                    value: context.watch<AppPreferences>().use24h,
                    onChanged: (v) =>
                        context.read<AppPreferences>().setUse24h(v),
                  ),
                  const Divider(height: 24),
                  SectionLabel(tr('Startup')),
                  const SizedBox(height: 4),
                  TvMenuTile(
                      icon: Icons.play_circle_outline,
                      title: tr('Playback at startup'),
                      subtitle: tr(_startupLabel),
                      onTap: _pickStartup),
                  const Divider(height: 24),
                  SettingsSection(title: tr('Multiview'), children: [
                    TvSwitchListTile(
                      title: Text(tr('Watch multiple channels')),
                      subtitle: Text(tr(
                          'Show multiview in the player and Settings. Each screen uses a provider connection.')),
                      value: !context.watch<AppPreferences>().hideMultiview,
                      onChanged: (value) => context.read<AppPreferences>().setHideMultiview(!value),
                    ),
                  ]),
                  SectionLabel(tr('Resume reminder')),
                  const SizedBox(height: 4),
                  TvSwitchListTile(
                    title: Text(tr('Show the "Hold > to resume" reminder')),
                    subtitle: Text(Platform.isWindows
                        ? tr(
                            'The pill at the bottom while a channel plays in the background. Off: hidden.')
                        : tr(
                            'The pill at the bottom while a channel plays in the background. Off: hidden — holding Right still resumes.')),
                    value: _showResumePill,
                    onChanged: (v) {
                      setState(() => _showResumePill = v);
                      LiveResumeHint.pillEnabled.value = v;
                      _storage.setShowResumePill(v);
                    },
                  ),
                  const Divider(height: 24),
                  SectionLabel(tr('History')),
                  const SizedBox(height: 4),
                  TvMenuTile(
                    icon: Icons.manage_search,
                    title: tr('Clear search & channel history'),
                    subtitle:
                        tr('Recent searches and the live channel History'),
                    onTap: _clearSearchAndChannelHistory,
                  ),
                ],
              ),
            ));
  }
}
