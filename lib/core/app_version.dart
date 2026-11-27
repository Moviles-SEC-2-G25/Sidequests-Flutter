/// App version attached to BQ1 telemetry, to compare releases. Keep in sync
/// with `version:` in pubspec.yaml, or override at build time with
/// `--dart-define=APP_VERSION=...`.
const String appVersion = String.fromEnvironment('APP_VERSION', defaultValue: '1.0.0+1');
