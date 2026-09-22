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

  await dotenv.load(fileName: '.env');

  final localDataSource = LocalDataSource();
  await localDataSource.init();

  await Supabase.initialize(
    url: Env.supabaseUrl,
    publishableKey: Env.supabasePublishableKey,
  );

  runApp(SidequestsApp(localDataSource: localDataSource));
}
