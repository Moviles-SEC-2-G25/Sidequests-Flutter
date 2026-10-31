import 'package:flutter_test/flutter_test.dart';
import 'package:sidequests/core/bq10_context.dart';
import 'package:sidequests/models/app_context.dart';

AppContext _context({int? weatherCode, bool isRainy = false}) => AppContext(
  timeOfDay: 'morning',
  dayOfWeek: 'monday',
  isConnected: true,
  weatherCode: weatherCode,
  isRainy: isRainy,
);

void main() {
  group('timeOfDayFor', () {
    String at(int hour, [int minute = 0]) => timeOfDayFor(DateTime(2026, 1, 1, hour, minute));

    test('uses only the four values, at every range boundary', () {
      expect(at(0), 'night');
      expect(at(5, 59), 'night');
      expect(at(6), 'morning');
      expect(at(11, 59), 'morning');
      expect(at(12), 'afternoon');
      expect(at(17, 59), 'afternoon');
      expect(at(18), 'evening');
      expect(at(21, 59), 'evening');
      expect(at(22), 'night');
      expect(at(23, 59), 'night');
    });
  });

  group('weatherConditionFor', () {
    test('no context is unknown', () {
      expect(weatherConditionFor(null), 'unknown');
    });

    test('a context without a weather reading is unknown, not clear', () {
      expect(weatherConditionFor(_context()), 'unknown');
    });

    // Same table as Kotlin's weatherCodeToCondition, at every range edge.
    const kotlinTable = {
      'clear': [0, 1],
      'cloudy': [2, 3, 45, 48],
      'rain': [51, 61, 67, 80, 82],
      'snow': [71, 77, 85, 86],
      'storm': [95, 99],
      'unknown': [4, 44, 50, 68, 70, 78, 79, 83, 84, 87, 94, 100, -1],
    };

    kotlinTable.forEach((condition, codes) {
      test('codes $codes are $condition', () {
        for (final code in codes) {
          expect(weatherConditionFor(_context(weatherCode: code)), condition, reason: 'code $code');
        }
      });
    });

    test('a storm stays storm even though AppContext.isRainy counts it as rain', () {
      expect(weatherConditionFor(_context(weatherCode: 95, isRainy: true)), 'storm');
    });
  });

  group('bq10Metadata', () {
    final evening = DateTime(2026, 1, 1, 19);

    test('carries exactly the same three keys as Kotlin', () {
      expect(bq10Metadata('gps', _context(weatherCode: 61, isRainy: true), evening), {
        'location_mode': 'gps',
        'time_of_day': 'evening',
        'weather_condition': 'rain',
      });
    });

    test('without a context the time still comes from the clock', () {
      expect(bq10Metadata('anywhere', null, evening), {
        'location_mode': 'anywhere',
        'time_of_day': 'evening',
        'weather_condition': 'unknown',
      });
    });
  });
}
