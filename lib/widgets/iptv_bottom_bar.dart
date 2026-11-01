import '../utils/interface_colors.dart';
import 'package:provider/provider.dart';
import '../services/app_preferences.dart';
import 'package:flutter/material.dart';

/// The original inset navigation panel, shared across portrait screens.
class IptvBottomBar extends StatelessWidget {
  const IptvBottomBar(
      {super.key, required this.selected, required this.onSelect});
  final String selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final prefs = context.watch<AppPreferences?>();
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 2, 0, 3),
        child: Container(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: interfaceColor(context, Colors.white24)),
            boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 12)],
          ),
          child: Row(children: [
            for (final item in [
              ('live', 'Live TV', Icons.live_tv_outlined),
              ('sports', 'Sports', Icons.sports),
              if (prefs?.hideMovies != true)
                ('movies', 'Movies', Icons.movie_outlined),
              if (prefs?.hideShows != true)
                ('series', 'Series', Icons.video_library_outlined),
              ('settings', 'Settings', Icons.settings_outlined),
            ])
              Expanded(
                  child: Semantics(
                selected: selected == item.$1,
                button: true,
                child: GestureDetector(
                  key: ValueKey('bottom-${item.$1}'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onSelect(item.$1),
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 44),
                    margin: const EdgeInsets.all(2),
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    decoration: BoxDecoration(
                      color: selected == item.$1
                          ? interfaceColor(context, Colors.white)
                              .withValues(alpha: .14)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(3),
                      border: Border.all(
                          color: selected == item.$1
                              ? interfaceColor(context, Colors.white24)
                              : Colors.transparent),
                    ),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Icon(item.$3,
                          size: 20,
                          color: selected == item.$1
                              ? scheme.primary
                              : interfaceColor(context, Colors.white70)),
                      const SizedBox(height: 2),
                      Text(item.$2,
                          maxLines: 1,
                          style: TextStyle(
                              fontSize: 10.5,
                              height: 1.2,
                              fontWeight: selected == item.$1
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              color: selected == item.$1
                                  ? interfaceColor(context, Colors.white)
                                  : interfaceColor(context, Colors.white70))),
                    ]),
                  ),
                ),
              )),
          ]),
        ),
      ),
    );
  }
}
