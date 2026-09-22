import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Reads the Supabase connection details the mobile client is allowed to use
/// (publishable key only, see Sidequests-Backend/docs/SECURITY.md).
class Env {
  Env._();

  static String get supabaseUrl => dotenv.env['SUPABASE_URL'] ?? '';

  static String get supabasePublishableKey =>
      dotenv.env['SUPABASE_PUBLISHABLE_KEY'] ?? '';

  static bool get isConfigured =>
      supabaseUrl.isNotEmpty && supabasePublishableKey.isNotEmpty;
}
