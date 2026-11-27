import 'package:flutter_test/flutter_test.dart';
import 'package:sidequests/core/bq11/commercial_blocks.dart';

void main() {
  // The points of Kotlin's Bq11ObservationTest, so both apps agree.
  test('inside each pilot block, with a precise fix', () {
    expect(commercialBlockAt(4.616, -74.08426, 5), kBq11PaloquemaoBlockId);
    expect(commercialBlockAt(4.69577, -74.031, 5), kBq11UsaquenBlockId);
  });

  test('the block ids are exactly Kotlin\'s', () {
    expect(kBq11UsaquenBlockId, 'usaquen-cra6a-c119');
    expect(kBq11PaloquemaoBlockId, 'paloquemao-market');
  });

  test('outside both blocks', () {
    expect(commercialBlockAt(4.601, -74.065, 5), isNull);
    expect(commercialBlockAt(4.6195, -74.0841, 5), isNull); // just north of Paloquemao
  });

  test('an accuracy outside 1..25 m never counts', () {
    expect(commercialBlockAt(4.616, -74.08426, 80), isNull);
    expect(commercialBlockAt(4.616, -74.08426, 25.01), isNull);
    expect(commercialBlockAt(4.616, -74.08426, 0.5), isNull);
    expect(commercialBlockAt(4.616, -74.08426, double.nan), isNull);
    expect(commercialBlockAt(4.616, -74.08426, 1), kBq11PaloquemaoBlockId);
  });

  test('edge: the same fix stops counting once its accuracy reaches the boundary', () {
    // Usaquén's segment is narrow: 5 m fits inside it, 25 m reaches an edge.
    expect(commercialBlockAt(4.69577, -74.031, 5), kBq11UsaquenBlockId);
    expect(commercialBlockAt(4.69577, -74.031, 25), isNull);
  });

  test('edge: a point just across a boundary is out, just inside is in', () {
    // Next to Paloquemao's first edge (4.6150192,-74.0841617 → 4.6157865,-74.0835081).
    final midLat = (4.6150192 + 4.6157865) / 2;
    final midLon = (-74.0841617 + -74.0835081) / 2;
    const step = 0.00009; // about 10 m, perpendicular to that edge
    expect(commercialBlockAt(midLat + step, midLon - step, 1), kBq11PaloquemaoBlockId);
    expect(commercialBlockAt(midLat - step, midLon + step, 1), isNull);
  });

  test('coordinates that are not numbers never count', () {
    expect(commercialBlockAt(double.nan, -74.08426, 5), isNull);
    expect(commercialBlockAt(4.616, double.infinity, 5), isNull);
  });
}
