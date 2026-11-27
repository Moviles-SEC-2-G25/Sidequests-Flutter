import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:sqflite/sqflite.dart' show databaseFactorySqflitePlugin;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'core/env.dart';
import 'data/local/local_data_source.dart';
import 'telemetry/bq1_telemetry.dart';
import 'telemetry/telemetry_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // BQ1 telemetry (mirror of the Kotlin app): uncaught errors and module
  // failures, tagged with whether they follow a long resume with a Nearby
  // quest, queued in SQLite and uploaded to analytics_events. No sqflite on
  // the web build.
  Bq1Telemetry? telemetry;
  if (!kIsWeb) {
    telemetry = Bq1Telemetry(
      store: TelemetryStore(factory: databaseFactorySqflitePlugin),
      sender: (events) => supabaseTelemetrySender(Supabase.instance.client)(events),
    );
  }

  // Crash capture: surface Flutter framework errors instead of a silent
  // black screen, mirroring the Kotlin app's UncaughtExceptionHandler, and
  // record them for BQ1.
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    telemetry?.recordUncaught(details.exception, details.stack);
  };

  // Errors no one awaited (a font or request that failed offline, a sensor
  // that went away) are logged, recorded for BQ1 and marked handled: they
  // must never take the app down or leave it in a broken state.
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('Unhandled error: $error\n$stack');
    telemetry?.recordUncaught(error, stack);
    return true;
  };

  // Release builds: a widget that fails to build shows a short message in
  // place of the default grey box. Debug keeps Flutter's red error screen.
  if (!kDebugMode) {
    ErrorWidget.builder = (_) => const Material(
      color: Colors.transparent,
      child: Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('No se pudo mostrar esta sección.', textAlign: TextAlign.center),
        ),
      ),
    );
  }

  await dotenv.load(fileName: '.env');

  final localDataSource = LocalDataSource();
  await localDataSource.init();

  await Supabase.initialize(
    url: Env.supabaseUrl,
    publishableKey: Env.supabasePublishableKey,
    // postgrest's default retries every GET 3 times over 7 s before failing;
    // a read that fails has the cache to fall back on right away.
    postgrestOptions: const PostgrestClientOptions(retryEnabled: false),
  );

  // After Supabase: the upload needs its client (and a signed-in user).
  // Telemetry must never keep the app from starting.
  try {
    await telemetry?.init();
  } catch (_) {}

  runApp(SidequestsApp(localDataSource: localDataSource, telemetry: telemetry));
}
