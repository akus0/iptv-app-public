import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/app_preferences.dart';
import '../l10n/l10n.dart';
import '../utils/interface_colors.dart';
import 'live_navigation_body.dart';

/// One menu for every wide top-level screen. Callers only supply selection,
/// destination handling and (optionally) their remembered remote focus nodes.
class MainNavigationRail extends StatefulWidget {
  const MainNavigationRail(
      {super.key,
      required this.selected,
      required this.onSelect,
      this.collapsed = false,
      this.focusNodes = const {},
      this.autofocus = false,
      this.onEnter});
  final String selected;
  final ValueChanged<String> onSelect;
  final bool collapsed, autofocus;
  final Map<String, FocusNode> focusNodes;
  final VoidCallback? onEnter;
  static const items = [
    (id: 'live', label: 'Live TV', icon: Icons.live_tv),
    (id: 'sports', label: 'Sports', icon: Icons.sports),
    (id: 'movies', label: 'Movies', icon: Icons.movie),
    (id: 'series', label: 'Series', icon: Icons.video_library),
    (id: 'settings', label: 'Settings', icon: Icons.settings_outlined),
  ];
  @override
  State<MainNavigationRail> createState() => _MainNavigationRailState();
}

class _MainNavigationRailState extends State<MainNavigationRail> {
  final _owned = <String, FocusNode>{};
  FocusNode _node(String id) =>
      widget.focusNodes[id] ??
      _owned.putIfAbsent(
          id, () => FocusNode(debugLabel: 'main-navigation-$id'));
  @override
  void dispose() {
    for (final node in _owned.values) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final prefs = context.watch<AppPreferences>();
    final items = MainNavigationRail.items
        .where((item) =>
            (item.id != 'movies' || !prefs.hideMovies) &&
            (item.id != 'series' || !prefs.hideShows))
        .toList();
    return ListView(padding: EdgeInsets.zero, children: [
      for (var i = 0; i < items.length; i++) ...[
        if (items[i].id == 'settings')
          Divider(
              height: 8,
              indent: 5,
              endIndent: 5,
              color: interfaceColor(context, Colors.white12)),
        Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
            child: Focus(
                onKeyEvent: (_, event) {
                  if (event is KeyUpEvent) return KeyEventResult.ignored;
                  final key = event.logicalKey;
                  if (key == LogicalKeyboardKey.arrowUp ||
                      key == LogicalKeyboardKey.arrowDown) {
                    final next =
                        (i + (key == LogicalKeyboardKey.arrowDown ? 1 : -1))
                            .clamp(0, items.length - 1);
                    _node(items[next].id).requestFocus();
                    return KeyEventResult.handled;
                  }
                  if (key == LogicalKeyboardKey.arrowRight &&
                      widget.onEnter != null) {
                    if (event is KeyDownEvent) widget.onEnter!();
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: AnimatedBuilder(
                    animation: _node(items[i].id),
                    builder: (context, _) => Material(
                        color: Colors.transparent,
                        animationDuration: Duration.zero,
                        child: InkWell(
                            key: ValueKey('main-nav-${items[i].id}'),
                            focusNode: _node(items[i].id),
                            autofocus: widget.autofocus &&
                                widget.selected == items[i].id,
                            splashFactory: NoSplash.splashFactory,
                            highlightColor: Colors.transparent,
                            onFocusChange: (hasFocus) {
                              if (!hasFocus) return;
                              Scrollable.ensureVisible(context,
                                  alignmentPolicy: ScrollPositionAlignmentPolicy
                                      .keepVisibleAtEnd);
                              Scrollable.ensureVisible(context,
                                  alignmentPolicy: ScrollPositionAlignmentPolicy
                                      .keepVisibleAtStart);
                            },
                            onTap: () => widget.onSelect(items[i].id),
                            child: LiveNavigationBody(
                                label: tr(items[i].label),
                                leading: Icon(items[i].icon),
                                collapsed: widget.collapsed,
                                focused: _node(items[i].id).hasFocus,
                                selected: widget.selected == items[i].id))))))
      ]
    ]);
  }
}
