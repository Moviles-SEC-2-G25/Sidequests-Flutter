import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';

import '../../core/distance.dart';
import '../../models/quest.dart';
import '../../viewmodel/quests/quest_view_model.dart';

/// Compass (magnetometer) arrow that points from the user's position to the
/// quest's coordinates. Needs a GPS fix (via the Context Manager) and a
/// device with a compass sensor; otherwise it degrades to a short message.
class QuestCompass extends StatelessWidget {
  final Quest quest;

  const QuestCompass({super.key, required this.quest});

  @override
  Widget build(BuildContext context) {
    final questLat = quest.latitude;
    final questLng = quest.longitude;
    if (questLat == null || questLng == null) return const SizedBox.shrink();

    final vm = context.watch<QuestViewModel>();
    final userLat = vm.userLatitude;
    final userLng = vm.userLongitude;

    // Kotlin's QuestCompass: a plain 16 dp card, 16 dp padding.
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: userLat == null || userLng == null
            ? Row(
                children: [
                  const Expanded(
                    child: Text('Turn on location to see the compass'),
                  ),
                  TextButton(
                    onPressed: vm.isLocatingUser ? null : vm.requestUserLocation,
                    child: const Text('Turn on'),
                  ),
                ],
              )
            : _CompassArrow(
                bearing: Geolocator.bearingBetween(
                  userLat,
                  userLng,
                  questLat,
                  questLng,
                ),
                distanceKm: haversineKm(userLat, userLng, questLat, questLng),
              ),
      ),
    );
  }
}

class _CompassArrow extends StatelessWidget {
  final double bearing;
  final double distanceKm;

  const _CompassArrow({required this.bearing, required this.distanceKm});

  @override
  Widget build(BuildContext context) {
    final distanceLabel = distanceKm < 1
        ? '${(distanceKm * 1000).round()} m'
        : '${distanceKm.toStringAsFixed(1)} km';
    final events = FlutterCompass.events;

    if (events == null) {
      return Text('Your device has no compass. Distance: $distanceLabel');
    }

    return StreamBuilder<CompassEvent>(
      stream: events,
      builder: (context, snapshot) {
        final heading = snapshot.data?.heading;
        if (heading == null) return const Text('Calibrating compass…');
        // Arrow rotation = bearing to the quest relative to where the phone points.
        final angle = (bearing - heading) * pi / 180;
        return Row(
          children: [
            // Micro-optimization: the compass sends a heading every ~32 ms, and
            // each new angle repaints up to the nearest repaint boundary. Without
            // this one that was the whole QuestDetailView scroll content; with
            // it, only the arrow's own layer is repainted.
            RepaintBoundary(
              child: Transform.rotate(
                angle: angle,
                child: Icon(
                  Icons.navigation,
                  size: 40,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Follow the arrow',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  Text(
                    '$distanceLabel from the quest',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
