import 'package:flutter_test/flutter_test.dart';
import 'package:sidequests/core/verification/check_in_sampling.dart';
import 'package:sidequests/core/verification/step_verification_strategy.dart';
import 'package:sidequests/core/verification/verification_strategies.dart';
import 'package:sidequests/models/quest.dart';

const _questLat = 4.6473;
const _questLon = -74.0600;

/// Degrees of latitude per meter (~111,195 m per degree).
const _degPerMeter = 1 / 111195;

Quest _quest({double? latitude = _questLat, double? longitude = _questLon}) => Quest(
  id: 'q',
  title: 'Quest',
  category: 'food',
  durationMinutes: 30,
  difficulty: 'easy',
  locationMode: 'gps',
  socialLevel: 'solo',
  latitude: latitude,
  longitude: longitude,
);

/// A fix [metersNorth] of the quest, with GPS error [accuracy].
VerificationEvidence _fix(double metersNorth, {double accuracy = 10}) => VerificationEvidence(
  locationAccess: LocationAccess.granted,
  latitude: _questLat + metersNorth * _degPerMeter,
  longitude: _questLon,
  accuracyMeters: accuracy,
);

void main() {
  group('strategyFor (who picks the strategy)', () {
    test('maps every verification_type the DB allows', () {
      expect(strategyFor('none'), isA<NoVerification>());
      expect(strategyFor('location'), isA<LocationVerification>());
      expect(strategyFor('photo'), isA<PhotoVerification>());
      expect(strategyFor('photo_and_location'), isA<CompositeVerification>());
    });

    test('an unknown type degrades to NoVerification instead of breaking the mission', () {
      expect(strategyFor('retina_scan'), isA<NoVerification>());
    });

    test('photo_and_location shows one row per part and needs both sensors', () {
      final strategy = strategyFor('photo_and_location');

      expect(strategy.parts.map((p) => p.runtimeType), [LocationVerification, PhotoVerification]);
      expect(strategy.needsLocation, isTrue);
      expect(strategy.needsPhoto, isTrue);
    });
  });

  group('NoVerification', () {
    test('is trivially verified but never auto-completes (no evidence required)', () {
      const strategy = NoVerification();

      expect(strategy.verify(_quest(), const VerificationEvidence()), isA<Verified>());
      expect(strategy.requiresEvidence, isFalse);
      expect(strategy.needsLocation, isFalse);
      expect(strategy.parts, isEmpty);
    });
  });

  group('LocationVerification (50 m, Haversine)', () {
    const strategy = LocationVerification();

    test('within 50 m with a precise fix → verified', () {
      expect(strategy.verify(_quest(), _fix(30)), isA<Verified>());
    });

    test('farther than 50 m → pending, with the distance for "estás a 120 m"', () {
      final result = strategy.verify(_quest(), _fix(120));

      expect(result, isA<Pending>());
      expect((result as Pending).distanceMeters, closeTo(120, 1));
    });

    test('inside the radius but with a fix too imprecise to prove it → still pending', () {
      expect(strategy.verify(_quest(), _fix(30, accuracy: 300)), isA<Pending>());
    });

    test('no fix yet → pending without a distance', () {
      final result = strategy.verify(
        _quest(),
        const VerificationEvidence(locationAccess: LocationAccess.granted),
      );

      expect(result, isA<Pending>());
      expect((result as Pending).distanceMeters, isNull);
    });

    test('a quest without coordinates (migration 003) can\'t be checked → manual fallback', () {
      final result = strategy.verify(_quest(latitude: null, longitude: null), _fix(0));

      expect(result, isA<Unavailable>());
      expect((result as Unavailable).reason, contains('no tiene ubicación'));
    });

    test('denied permission, GPS off and approximate-only location each say why', () {
      String reason(LocationAccess access) =>
          (strategy.verify(_quest(), VerificationEvidence(locationAccess: access)) as Unavailable)
              .reason;

      expect(reason(LocationAccess.denied), contains('Permite'));
      expect(reason(LocationAccess.serviceDisabled), contains('GPS'));
      expect(reason(LocationAccess.approximateOnly), contains('precisa'));
    });
  });

  group('PhotoVerification (feature f)', () {
    const strategy = PhotoVerification();
    const uploaded = VerificationEvidence(photoPath: 'user/attempt/quest/step-1-x.jpg');

    test('pending until a photo is uploaded and registered, then verified', () {
      expect(strategy.verify(_quest(), const VerificationEvidence()), isA<Pending>());
      expect(strategy.verify(_quest(), uploaded), isA<Verified>());
    });

    test('blocks the "Completar" button until the photo is uploaded', () {
      expect(strategy.allowsManualCompletion(_quest(), const VerificationEvidence()), isFalse);
      expect(strategy.allowsManualCompletion(_quest(), uploaded), isTrue);
    });
  });

  test('location never blocks the button (GPS fails indoors); none never does', () {
    expect(const LocationVerification().allowsManualCompletion(_quest(), _fix(500)), isTrue);
    expect(const NoVerification().allowsManualCompletion(_quest(), const VerificationEvidence()), isTrue);
  });

  group('CompositeVerification (photo_and_location)', () {
    final strategy = strategyFor('photo_and_location');

    test('being at the place is not enough while the photo is missing', () {
      expect(strategy.verify(_quest(), _fix(10)), isA<Pending>());
      expect(strategy.allowsManualCompletion(_quest(), _fix(10)), isFalse);
    });

    test('verified only when every part is', () {
      final atPlaceWithPhoto = VerificationEvidence(
        locationAccess: LocationAccess.granted,
        latitude: _questLat,
        longitude: _questLon,
        accuracyMeters: 10,
        photoPath: '/tmp/p.jpg',
      );
      final farWithPhoto = VerificationEvidence(
        locationAccess: LocationAccess.granted,
        latitude: _questLat + 500 * _degPerMeter,
        longitude: _questLon,
        accuracyMeters: 10,
        photoPath: '/tmp/p.jpg',
      );

      expect(strategy.verify(_quest(), atPlaceWithPhoto), isA<Verified>());
      expect(strategy.verify(_quest(), farWithPhoto), isA<Pending>());
    });
  });

  group('checkInSampling (GPS adapted to proximity and battery)', () {
    test('far away or unknown: balanced and sparse', () {
      expect(checkInSampling(lowBattery: false), (
        precision: CheckInPrecision.balanced,
        distanceFilterMeters: 50,
      ));
      expect(checkInSampling(lowBattery: false, distanceMeters: 2000).precision,
          CheckInPrecision.balanced);
    });

    test('within 300 m: precise, because 50 m can\'t be confirmed otherwise', () {
      expect(checkInSampling(lowBattery: false, distanceMeters: 300), (
        precision: CheckInPrecision.precise,
        distanceFilterMeters: 5,
      ));
    });

    test('low battery samples less, but still precise once near', () {
      expect(checkInSampling(lowBattery: true), (
        precision: CheckInPrecision.coarse,
        distanceFilterMeters: 100,
      ));
      expect(checkInSampling(lowBattery: true, distanceMeters: 100), (
        precision: CheckInPrecision.precise,
        distanceFilterMeters: 15,
      ));
    });
  });
}
