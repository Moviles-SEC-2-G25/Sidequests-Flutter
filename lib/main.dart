import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'core/env.dart';
import 'data/local/local_data_source.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Crash capture: surface Flutter framework errors instead of a silent
  // black screen, mirroring the Kotlin app's UncaughtExceptionHandler.
  FlutterError.onError = FlutterError.presentError;

  // Errors no one awaited (a font or request that failed offline, a sensor
  // that went away) are logged and marked handled: they must never take the
  // app down or leave it in a broken state.
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('Unhandled error: $error\n$stack');
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
          child: Text('This section could not be displayed.', textAlign: TextAlign.center),
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

  runApp(SidequestsApp(localDataSource: localDataSource));
}
