import 'package:flutter/material.dart';

/// Changing presentation never reimports the playlist or rewrites channel IDs.
class PlaylistOrganisationPicker extends StatelessWidget {
  const PlaylistOrganisationPicker(
      {super.key,
      this.focusNode,
      this.showDescription = true,
      required this.value,
      required this.onChanged});
  final FocusNode? focusNode;
  final bool showDescription;
  final String value;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<String>(
            key: ValueKey(value),
            focusNode: focusNode,
            initialValue: value,
            isExpanded: true,
            decoration:
                const InputDecoration(labelText: 'Playlist organisation'),
            items: const [
              DropdownMenuItem(
                  value: 'organised', child: Text('Organise with iptv-app')),
              DropdownMenuItem(
                  value: 'provider', child: Text('Keep provider categories')),
            ],
            onChanged: onChanged == null
                ? null
                : (v) {
                    if (v != null) onChanged!(v);
                  },
          ),
          if (showDescription) const SizedBox(height: 8),
          if (showDescription)
            Text(
                value == 'provider'
                    ? 'Keep your provider’s categories. You can change this later.'
                    : 'Organised categories for Live TV, Movies and Series. Streams, guide links and favourites stay unchanged.',
                style: Theme.of(context).textTheme.bodySmall),
        ],
      );
}
