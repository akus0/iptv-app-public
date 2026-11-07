import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart';
import '../models/epg_program.dart';
import '../services/epg_service.dart';

/// A database batch updates its channels, without rebuilding the whole guide.
class GuideProgrammeRow extends StatefulWidget {
  const GuideProgrammeRow(
      {super.key,
      required this.epg,
      required this.channelId,
      required this.isActive,
      required this.builder,
      this.enabled = true,
      this.renderKey,
      this.fastBrowsing});

  /// Optional identity of the builder's visual inputs. Equal keys reuse its
  /// child while programmes are unchanged. Callbacks in that child must read
  /// current state, or be included in the key. Inherited theme/layout changes
  /// still reach the child normally. The cache lives only as long as this row.
  final Object? renderKey;
  final ValueListenable<bool>? fastBrowsing;
  final EpgService epg;
  final String channelId;
  final bool enabled;
  final bool Function() isActive;
  final Widget Function(List<EpgProgram>) builder;

  @override
  State<GuideProgrammeRow> createState() => _GuideProgrammeRowState();
}

class _GuideProgrammeRowState extends State<GuideProgrammeRow> {
  late List<EpgProgram> _rows;
  late String _id;
  Widget? _child;

  void _read() {
    _id = normalizeEpgId(widget.channelId);
    final rows = !widget.enabled
        ? const <EpgProgram>[]
        : widget.fastBrowsing?.value == true
            ? widget.epg.peekPrograms(_id)
            : widget.epg.getPrograms(_id);
    if (_child != null && !identical(rows, _rows)) _child = null;
    _rows = rows;
  }

  @override
  void initState() {
    super.initState();
    _read();
    widget.epg.guideRowsLoaded.addListener(_changed);
    widget.fastBrowsing?.addListener(_browsingChanged);
  }

  @override
  void didUpdateWidget(GuideProgrammeRow old) {
    super.didUpdateWidget(old);
    if (old.fastBrowsing != widget.fastBrowsing) {
      old.fastBrowsing?.removeListener(_browsingChanged);
      widget.fastBrowsing?.addListener(_browsingChanged);
    }
    if (old.epg != widget.epg) {
      old.epg.guideRowsLoaded.removeListener(_changed);
      widget.epg.guideRowsLoaded.addListener(_changed);
    }
    if (old.renderKey != widget.renderKey ||
        old.enabled != widget.enabled ||
        old.epg != widget.epg ||
        old.channelId != widget.channelId) {
      _child = null;
    }
    _read();
  }

  void _browsingChanged() {
    if (!widget.isActive() || widget.fastBrowsing?.value == true) return;
    setState(_read);
  }

  void _changed() {
    if (!widget.enabled ||
        !widget.isActive() ||
        widget.fastBrowsing?.value == true) {
      return;
    }
    final changed = widget.epg.lastLoadedGuideChannelIds;
    if (changed != null && !changed.contains(_id)) return;
    final rows = widget.epg.getPrograms(_id);
    if (identical(rows, _rows)) return;
    setState(() {
      _rows = rows;
      _child = null;
    });
  }

  @override
  void dispose() {
    widget.fastBrowsing?.removeListener(_browsingChanged);
    widget.epg.guideRowsLoaded.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.renderKey == null
      ? widget.builder(_rows)
      : _child ??= widget.builder(_rows);
}
