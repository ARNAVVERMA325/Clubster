/// Connection details for the Clubster FastAPI backend (as opposed to
/// Supabase, which is configured separately in supabase_config.dart).
class ApiConfig {
  static const String baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://localhost:8000/api',
  );
}
