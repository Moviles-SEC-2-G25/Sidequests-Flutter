/// Single error type surfaced by the Repository layer to ViewModels.
///
/// Repositories translate Supabase/local storage failures into this type so
/// ViewModels never depend on data-source-specific exceptions.
class AppException implements Exception {
  final String message;

  const AppException(this.message);

  @override
  String toString() => message;
}
