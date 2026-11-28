/// BQ1: software modules used to answer "at which module does the app most
/// frequently crash". Same codes as the Kotlin app, so both land in the same
/// groups of `analytics_events.metadata->>'module'`.
enum AppModule {
  auth('auth'),
  catalog('catalog'),
  recommendations('recommendations'),
  context('context'),
  geocoding('geocoding'),
  questProgress('quest_progress'),
  photoProof('photo_proof'),
  sensors('sensors'),
  analytics('analytics'),
  ui('ui'),
  unknown('unknown');

  final String code;

  const AppModule(this.code);
}

/// Something that can record a module failure (Bq1Telemetry in the app;
/// [FailureReporter.none] in tests).
abstract interface class FailureReporter {
  void report(AppModule module, Object? error, {String? message});

  static const FailureReporter none = _NoFailureReporter();
}

class _NoFailureReporter implements FailureReporter {
  const _NoFailureReporter();

  @override
  void report(AppModule module, Object? error, {String? message}) {}
}

/// Maps an uncaught error to the module where it happened, using the first
/// stack frame that belongs to the app. Paths follow the project structure,
/// like the Kotlin classifier follows its packages.
abstract final class ModuleClassifier {
  static const _root = 'package:sidequests/';

  // Order matters: more specific prefixes first.
  static const List<(String, AppModule)> _rules = [
    ('data/services/reverse_geocoding', AppModule.geocoding),
    ('data/services/photo_capture', AppModule.photoProof),
    ('data/services/shake_detector', AppModule.sensors),
    ('data/services/step_counter', AppModule.sensors),
    ('data/services/ambient_light', AppModule.sensors),
    ('data/services/biometric', AppModule.auth),
    ('data/services/', AppModule.context),
    ('data/context/', AppModule.context),
    ('repository/auth', AppModule.auth),
    ('viewmodel/auth/', AppModule.auth),
    ('view/auth/', AppModule.auth),
    ('core/', AppModule.recommendations),
    ('analytics/', AppModule.analytics),
    ('telemetry/', AppModule.analytics),
    ('repository/', AppModule.catalog),
    ('data/', AppModule.catalog),
    ('view/', AppModule.ui),
    ('viewmodel/', AppModule.ui),
    ('app.dart', AppModule.ui),
    ('main.dart', AppModule.ui),
  ];

  static AppModule fromStackTrace(StackTrace? stackTrace) {
    if (stackTrace == null) return AppModule.unknown;
    for (final line in stackTrace.toString().split('\n')) {
      final start = line.indexOf(_root);
      if (start < 0) continue;
      return fromPath(line.substring(start + _root.length));
    }
    return AppModule.unknown;
  }

  /// [path] relative to lib/, e.g. `repository/quest_repository.dart:12:3`.
  static AppModule fromPath(String path) {
    for (final (prefix, module) in _rules) {
      if (path.startsWith(prefix)) return module;
    }
    return AppModule.unknown;
  }
}
