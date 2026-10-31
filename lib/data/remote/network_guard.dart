import 'package:connectivity_plus/connectivity_plus.dart';

/// Thrown instead of calling Supabase when the device has no network.
class NoNetworkException implements Exception {
  const NoNetworkException();
}

/// Bounds how long the user can wait on Supabase. Without a connection a call
/// doesn't fail right away: with an expired token, gotrue first spends about
/// 12 s retrying the refresh, and there's no option to skip that. So with no
/// network the call isn't made, and any other call gets [timeout]; both end up
/// in the caller's existing "no connection" path (cache or queue).
class NetworkGuard {
  static const timeout = Duration(seconds: 5);

  final Future<bool> Function()? _isOffline;

  /// Without [isOffline], only the timeout applies.
  const NetworkGuard({Future<bool> Function()? isOffline}) : _isOffline = isOffline;

  factory NetworkGuard.connectivity() => NetworkGuard(
    isOffline: () async =>
        (await Connectivity().checkConnectivity()).contains(ConnectivityResult.none),
  );

  /// Unknown connectivity counts as online: the timeout still applies.
  Future<bool> get isOffline async {
    try {
      return await _isOffline?.call() ?? false;
    } catch (_) {
      return false;
    }
  }

  /// A timed-out call may still reach the server, so only use it for requests
  /// that are safe to repeat.
  Future<T> run<T>(Future<T> Function() request) async {
    if (await isOffline) throw const NoNetworkException();
    return request().timeout(timeout);
  }
}
