import 'package:flutter_test/flutter_test.dart';
import 'package:sidequests/core/ambient_light_classifier.dart';

/// Same behaviour as the Kotlin app's AmbientLightClassifier.
void main() {
  final t0 = DateTime(2026, 11, 27, 20);
  DateTime at(int millis) => t0.add(Duration(milliseconds: millis));

  test('the first reading decides right away', () {
    expect(AmbientLightClassifier().onReading(5, t0), isTrue);
    expect(AmbientLightClassifier().onReading(300, t0), isFalse);
  });

  test('between the two thresholds the current decision stays (hysteresis)', () {
    final classifier = AmbientLightClassifier()..onReading(5, t0);

    expect(classifier.onReading(25, at(5000)), isNull);
    expect(classifier.isDark, isTrue);
  });

  test('a change applies only after it holds for 2 seconds', () {
    final classifier = AmbientLightClassifier()..onReading(5, t0);

    expect(classifier.onReading(300, at(100)), isNull);
    expect(classifier.hasPendingChange, isTrue);
    expect(classifier.onReading(300, at(1500)), isNull);
    expect(classifier.onReading(300, at(2200)), isFalse);
    expect(classifier.isDark, isFalse);
    expect(classifier.hasPendingChange, isFalse);
  });

  test('a hand passing over the phone does not switch the theme', () {
    final classifier = AmbientLightClassifier()..onReading(300, t0);

    expect(classifier.onReading(2, at(100)), isNull);
    expect(classifier.onReading(300, at(600)), isNull);
    expect(classifier.hasPendingChange, isFalse);
    expect(classifier.onReading(300, at(5000)), isNull);
    expect(classifier.isDark, isFalse);
  });
}
