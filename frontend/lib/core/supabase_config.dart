import 'package:supabase_flutter/supabase_flutter.dart';

/// Supabase project connection details.
///
/// TODO: these read from --dart-define at build time so nothing is
/// hardcoded; wire up real values via `--dart-define=SUPABASE_URL=...
/// --dart-define=SUPABASE_PUBLISHABLE_KEY=...` (or a build-time config
/// file) before this is used against a real project.
class SupabaseConfig {
  static const String url = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://your-project-ref.supabase.co',
  );

  static const String publishableKey = String.fromEnvironment(
    'SUPABASE_PUBLISHABLE_KEY',
    defaultValue: 'your-publishable-key',
  );

  static Future<void> initialize() {
    return Supabase.initialize(url: url, publishableKey: publishableKey);
  }
}

SupabaseClient get supabase => Supabase.instance.client;
