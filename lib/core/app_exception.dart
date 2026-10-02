/// Single error type surfaced by the Repository layer to ViewModels.
///
/// Repositories translate Supabase/local storage failures into this type so
/// ViewModels never depend on data-source-specific exceptions.
class AppException implements Exception {
  final String message;

  /// True when trying again later can succeed (no connection, server
  /// hiccup) — the Retry tactic keeps the work and offers "Reintentar".
  /// False when it never will (rejected by RLS, invalid file).
  final bool isRetryable;

  const AppException(this.message, {this.isRetryable = false});

  @override
  String toString() => message;
}
