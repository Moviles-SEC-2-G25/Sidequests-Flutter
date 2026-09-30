import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../data/services/reverse_geocoding_service.dart';
import '../../models/quest.dart';

/// Shows the quest's street address, resolved through the external
/// reverse-geocoding service. Hidden when the quest has no coordinates or the
/// lookup fails.
class QuestAddress extends StatefulWidget {
  final Quest quest;

  const QuestAddress({super.key, required this.quest});

  @override
  State<QuestAddress> createState() => _QuestAddressState();
}

class _QuestAddressState extends State<QuestAddress> {
  Future<String?>? _address;

  @override
  void initState() {
    super.initState();
    final lat = widget.quest.latitude;
    final lng = widget.quest.longitude;
    if (lat != null && lng != null) {
      _address = ReverseGeocodingService().addressFor(lat, lng);
    }
  }

  @override
  Widget build(BuildContext context) {
    final future = _address;
    if (future == null) return const SizedBox.shrink();
    return FutureBuilder<String?>(
      future: future,
      builder: (context, snapshot) {
        final address = snapshot.data;
        if (snapshot.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: LinearProgressIndicator(minHeight: 2),
          );
        }
        if (address == null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.place_outlined, size: 18, color: AppColors.secondaryDark),
              const SizedBox(width: 6),
              Expanded(child: Text(address, style: Theme.of(context).textTheme.bodySmall)),
            ],
          ),
        );
      },
    );
  }
}
