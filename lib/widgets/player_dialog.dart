import '../utils/guarded_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/app_preferences.dart';
import '../l10n/l10n.dart';
import 'player_chrome.dart';

/// Fixed heading with a separately scrolling body, shared by player panels.
class PlayerDialog extends StatefulWidget {
  const PlayerDialog(
      {super.key,
      required this.title,
      required this.child,
      this.subtitle,
      this.icon = Icons.tune_rounded,
      this.width = 500,
      this.keyboardScroll = false});
  final String title;
  final String? subtitle;
  final IconData icon;
  final Widget child;
  final double width;
  final bool keyboardScroll;
  @override
  State<PlayerDialog> createState() => _PlayerDialogState();
}

class _PlayerDialogState extends State<PlayerDialog> {
  final _scroll = ScrollController();
  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  KeyEventResult _key(FocusNode _, KeyEvent event) {
    if (!widget.keyboardScroll || event is KeyUpEvent || !_scroll.hasClients) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final double delta;
    if (key == LogicalKeyboardKey.arrowDown) {
      delta = 72;
    } else if (key == LogicalKeyboardKey.arrowUp) {
      delta = -72;
    } else if (key == LogicalKeyboardKey.pageDown) {
      delta = _scroll.position.viewportDimension * .8;
    } else if (key == LogicalKeyboardKey.pageUp) {
      delta = -_scroll.position.viewportDimension * .8;
    } else {
      return KeyEventResult.ignored;
    }
    _scroll.jumpTo(
        (_scroll.offset + delta).clamp(0, _scroll.position.maxScrollExtent));
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => Focus(
      canRequestFocus: false,
      onKeyEvent: _key,
      child: Dialog(
          backgroundColor: const Color(0xE6141B23),
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          clipBehavior: Clip.antiAlias,
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: const BorderSide(color: Color(0xFF303C49))),
          child: ConstrainedBox(
              constraints: BoxConstraints(
                  maxWidth: widget.width,
                  maxHeight: MediaQuery.sizeOf(context).height * .86),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Padding(
                    padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
                    child: Row(children: [
                      Icon(widget.icon, size: 20, color: playerMuted),
                      const SizedBox(width: 10),
                      Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            Text(tr(widget.title),
                                style: const TextStyle(
                                    fontSize: 15, fontWeight: FontWeight.w600)),
                            if (widget.subtitle?.isNotEmpty == true)
                              Padding(
                                  padding: const EdgeInsets.only(top: 3),
                                  child: Text(widget.subtitle!,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontSize: 11, color: playerMuted))),
                          ])),
                      PlayerAction(
                          autofocus: widget.keyboardScroll &&
                              context.read<AppPreferences>().isTelevision,
                          icon: Icons.close_rounded,
                          label: 'Close',
                          compact: true,
                          onPressed: () => popRouteIfCurrent(context)),
                    ])),
                const Divider(height: 1, color: Color(0xFF2B3642)),
                Flexible(
                    child: Scrollbar(
                        controller: _scroll,
                        thumbVisibility: true,
                        thickness: 2,
                        child: SingleChildScrollView(
                            controller: _scroll,
                            key: const ValueKey('player-dialog-scroll'),
                            padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
                            child: widget.child))),
              ]))));
}

class PlayerSection extends StatelessWidget {
  const PlayerSection(this.title, {super.key});
  final String title;
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 13, 4, 6),
      child: Text(tr(title).toUpperCase(),
          style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: .8,
              color: playerMuted)));
}

class PlayerSettingRow extends StatelessWidget {
  const PlayerSettingRow(
      {super.key,
      required this.icon,
      required this.title,
      this.detail,
      this.onTap,
      this.selected = false,
      this.autofocus = false});
  final IconData icon;
  final String title;
  final String? detail;
  final VoidCallback? onTap;
  final bool selected, autofocus;
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: TextButton(
          autofocus: autofocus,
          onFocusChange: (focused) {
            if (!focused) return;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!context.mounted) return;
              Scrollable.ensureVisible(context,
                  alignmentPolicy:
                      ScrollPositionAlignmentPolicy.keepVisibleAtEnd);
              Scrollable.ensureVisible(context,
                  alignmentPolicy:
                      ScrollPositionAlignmentPolicy.keepVisibleAtStart);
            });
          },
          onPressed: onTap,
          style: ButtonStyle(
              padding: const WidgetStatePropertyAll(
                  EdgeInsets.symmetric(horizontal: 10, vertical: 7)),
              minimumSize: const WidgetStatePropertyAll(Size.fromHeight(48)),
              foregroundColor: const WidgetStatePropertyAll(Colors.white),
              backgroundColor: WidgetStateProperty.resolveWith((s) =>
                  s.contains(WidgetState.focused)
                      ? const Color(0xFF30485E)
                      : const Color(0x801E2935)),
              shape: WidgetStatePropertyAll(RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(4))),
              side: WidgetStateProperty.resolveWith((s) => BorderSide(
                  color: s.contains(WidgetState.focused)
                      ? Theme.of(context).colorScheme.primary
                      : Colors.transparent))),
          child: Row(children: [
            Icon(icon,
                size: 20,
                color: selected
                    ? Theme.of(context).colorScheme.primary
                    : playerMuted),
            const SizedBox(width: 12),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(tr(title),
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w500)),
                  if (detail?.isNotEmpty == true)
                    Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(detail!,
                            style: const TextStyle(
                                fontSize: 11,
                                height: 1.25,
                                color: playerMuted))),
                ])),
            if (onTap != null)
              Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Icon(
                      selected
                          ? Icons.check_rounded
                          : Icons.chevron_right_rounded,
                      size: 18,
                      color: selected
                          ? Theme.of(context).colorScheme.primary
                          : playerMuted)),
          ])));
}
