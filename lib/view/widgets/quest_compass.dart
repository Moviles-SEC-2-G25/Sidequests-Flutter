import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
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

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.15),
        ),
      ),
      child: userLat == null || userLng == null
          ? Row(
              children: [
                const Icon(
                  Icons.explore_outlined,
                  color: AppColors.secondaryDark,
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text('Activa tu ubicación para ver la brújula'),
                ),
                TextButton(
                  onPressed: vm.isLocatingUser ? null : vm.requestUserLocation,
                  child: const Text('Activar'),
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
      return Text('Tu dispositivo no tiene brújula. Distancia: $distanceLabel');
    }

    return StreamBuilder<CompassEvent>(
      stream: events,
      builder: (context, snapshot) {
        final heading = snapshot.data?.heading;
        if (heading == null) return const Text('Calibrando brújula…');
        // Arrow rotation = bearing to the quest relative to where the phone points.
        final angle = (bearing - heading) * pi / 180;
        return Row(
          children: [
            Transform.rotate(
              angle: angle,
              child: const Icon(
                Icons.navigation,
                size: 48,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Sigue la flecha',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  Text(
                    'A $distanceLabel de la misión',
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
