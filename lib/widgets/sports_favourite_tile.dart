import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/sports.dart';
import 'sports_widgets.dart';

/// Focus and selection repaint this row without rebuilding the favourites
/// search, filters or list. The local Material also bounds ink repainting.
class SportsFavouriteTile extends StatefulWidget {
  const SportsFavouriteTile({
    super.key,
    required this.entry,
    required this.name,
    required this.league,
    required this.selection,
    required this.onFocusChange,
    required this.onTap,
    required this.onRemove,
    this.logo,
    this.striped = false,
  });

  final FollowedTeam entry;
  final String name, league;
  final String? logo;
  final bool striped;
  final ValueListenable<FollowedTeam?> selection;
  final ValueChanged<bool> onFocusChange;
  final VoidCallback? onTap;
  final VoidCallback onRemove;

  @override
  State<SportsFavouriteTile> createState() => _SportsFavouriteTileState();
}

class _SportsFavouriteTileState extends State<SportsFavouriteTile> {
  final _visual = ValueNotifier<(bool, bool)>((false, false));
  final _rowFocus = FocusNode();
  final _removeFocus = FocusNode();

  void _selectionChanged() => _visual.value =
      (_visual.value.$1, widget.selection.value == widget.entry);

  @override
  void initState() {
    super.initState();
    widget.selection.addListener(_selectionChanged);
    _selectionChanged();
  }

  @override
  void didUpdateWidget(SportsFavouriteTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selection != widget.selection) {
      oldWidget.selection.removeListener(_selectionChanged);
      widget.selection.addListener(_selectionChanged);
    }
    _selectionChanged();
  }

  @override
  void dispose() {
    widget.selection.removeListener(_selectionChanged);
    _rowFocus.dispose();
    _removeFocus.dispose();
    _visual.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ValueListenableBuilder<(bool, bool)>(
        valueListenable: _visual,
        child: Focus(
            canRequestFocus: false,
            onKeyEvent: (_, event) {
              if (event is! KeyDownEvent) return KeyEventResult.ignored;
              // The star is inside the row's focus rectangle, so geometric
              // traversal cannot reliably reach it with a TV remote.
              if (_rowFocus.hasPrimaryFocus &&
                  event.logicalKey == LogicalKeyboardKey.arrowRight) {
                _removeFocus.requestFocus();
                return KeyEventResult.handled;
              }
              if (_removeFocus.hasFocus &&
                  event.logicalKey == LogicalKeyboardKey.arrowLeft) {
                _rowFocus.requestFocus();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: ListTile(
              focusNode: _rowFocus,
              key: ValueKey(widget.entry.key),
              dense: true,
              minTileHeight: 48,
              contentPadding: const EdgeInsets.only(left: 10, right: 4),
              horizontalTitleGap: 10,
              focusColor: Colors.transparent,
              hoverColor: Colors.transparent,
              selected: false,
              leading: SportsLogo(
                  url: widget.logo,
                  size: 28,
                  fallback: widget.name,
                  animate: false),
              title: Text(widget.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600)),
              subtitle: Text(widget.league,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 10.5, color: colors.onSurfaceVariant)),
              onFocusChange: (focused) {
                _visual.value = (focused, _visual.value.$2);
                widget.onFocusChange(focused);
              },
              onTap: widget.onTap,
              trailing: IconButton(
                  focusNode: _removeFocus,
                  tooltip: 'Remove favourite',
                  icon: const Icon(Icons.star, size: 18),
                  onPressed: widget.onRemove),
            )),
        builder: (context, visual, child) {
          final (focused, selected) = visual;
          return Semantics(
            selected: selected,
            child: Material(
              animationDuration: Duration.zero,
              color: focused
                  ? colors.primaryContainer
                  : selected
                      ? colors.primary.withValues(alpha: .07)
                      : widget.striped
                          ? colors.onSurface.withValues(alpha: .025)
                          : Colors.transparent,
              shape: Border(
                  left: BorderSide(
                      width: 2,
                      color: focused || selected
                          ? colors.primary
                          : Colors.transparent)),
              child: child,
            ),
          );
        });
  }
}
