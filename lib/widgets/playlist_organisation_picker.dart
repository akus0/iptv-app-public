import 'package:flutter/material.dart';

/// Changing presentation never reimports the playlist or rewrites channel IDs.
class PlaylistOrganisationPicker extends StatelessWidget {
  const PlaylistOrganisationPicker(
      {super.key, required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<String>(
            key: ValueKey(value),
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
          const SizedBox(height: 8),
          Text(
              value == 'provider'
                  ? 'Original Live TV, Movies and Series categories. You can change this later.'
                  : 'Tidy Live TV groups and organised Movies and Series folders. Original streams, guide links and favourites stay unchanged.',
              style: Theme.of(context).textTheme.bodySmall),
        ],
      );
}
