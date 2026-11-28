import 'package:flutter/foundation.dart' show debugPrint;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/app_exception.dart';
import '../data/local/local_data_source.dart';
import '../data/remote/network_guard.dart';
import '../data/remote/supabase_remote_data_source.dart';
import '../models/group_challenge.dart';

/// No answer came back (dropped connection, timeout): the server may or may
/// not have applied the request. Sending the same request id again is safe.
class GroupActionUnconfirmedException extends AppException {
  const GroupActionUnconfirmedException()
    : super('No sabemos si se guardó. Reconecta y reintenta: es seguro.', isRetryable: true);
}

/// The request never left the phone (NetworkGuard saw no network), so it
/// wasn't applied and there's nothing to confirm.
class GroupActionNotSentException extends AppException {
  const GroupActionNotSentException()
    : super('Sin conexión: no se envió. Conéctate e inténtalo de nuevo.', isRetryable: true);
}

/// One of the two lists of [GroupChallengeRepository.loadLists]: the server's
/// rows, or why they didn't come ([error]). A failure never carries rows, so
/// the ViewModel keeps whatever it was showing.
class GroupListResult {
  final List<GroupChallenge>? challenges;
  final AppException? error;

  const GroupListResult.success(List<GroupChallenge> this.challenges) : error = null;

  const GroupListResult.failure(AppException this.error) : challenges = null;

  bool get isSuccess => error == null;
}

typedef GroupChallengeLists = ({GroupListResult mine, GroupListResult available});

/// Single source of truth for group challenges (Backend migration 011), the
/// Flutter side of Kotlin's GroupChallengeRepository. Every call goes through
/// [NetworkGuard] (no call without network, 5 s limit). Each list the server
/// sends is saved in Hive, so the screen opens with the last one even offline
/// or after a restart; the request whose result is unknown is saved there too.
class GroupChallengeRepository {
  static const _listsUnavailableMessage = 'No se pudo actualizar esta lista.';

  final SupabaseRemoteDataSource _remoteDataSource;
  final LocalDataSource _localDataSource;
  final NetworkGuard _network;

  GroupChallengeRepository(
    this._remoteDataSource,
    this._localDataSource, {
    this._network = const NetworkGuard(),
  });

  /// Multithreading strategy (concurrent I/O): "Mis retos" and "Retos
  /// disponibles" are two independent RPCs, so both are in flight at once
  /// and the screen waits for the slower one, not for their sum. Mirror of
  /// Kotlin's GroupChallengeLoader (two `async` on Dispatchers.IO inside a
  /// coroutineScope): each read catches its own failure, so Future.wait never
  /// short-circuits and a failed list doesn't erase the other one.
  Future<GroupChallengeLists> loadLists() async {
    final results = await Future.wait([_loadList(mine: true), _loadList(mine: false)]);
    return (mine: results[0], available: results[1]);
  }

  Future<GroupListResult> _loadList({required bool mine}) async {
    final List<GroupChallenge> challenges;
    try {
      final rows = await _network.run(() => _remoteDataSource.groupChallengeList(mine: mine));
      challenges = rows.map(GroupChallenge.fromJson).toList();
    } on PostgrestException catch (e) {
      return GroupListResult.failure(AppException(_postgrestMessage(e)));
    } catch (_) {
      // No network, timeout, dropped connection, or a row of the wrong shape.
      return const GroupListResult.failure(
        AppException(_listsUnavailableMessage, isRetryable: true),
      );
    }
    try {
      await _localDataSource.cacheGroupChallenges(
        mine: mine,
        rows: challenges.map((c) => c.toJson()).toList(),
      );
    } catch (error) {
      // The list on screen is still fresh; only the copy for later is lost.
      debugPrint('Group challenges: list not saved ($error)');
    }
    return GroupListResult.success(challenges);
  }

  /// The last list the server sent of each kind; null for one never received
  /// on this device (or unreadable), as opposed to an empty one.
  ({List<GroupChallenge>? mine, List<GroupChallenge>? available}) savedLists() =>
      (mine: _savedList(mine: true), available: _savedList(mine: false));

  List<GroupChallenge>? _savedList({required bool mine}) {
    try {
      return _localDataSource.getGroupChallenges(mine: mine)?.map(GroupChallenge.fromJson).toList();
    } catch (_) {
      return null;
    }
  }

  /// Sends one create/join/progress. Returns the server's answer, whether it
  /// applied it (`ok`) or refused it (`ok` false, with its reason): either way
  /// the server logged it. Throws:
  /// - [GroupActionUnconfirmedException] when no answer came back, so the
  ///   result is unknown (retry with the same [GroupAction.requestId]);
  /// - [GroupActionNotSentException] when there was no network to send it;
  /// - [AppException] when PostgREST answered with an error.
  Future<GroupActionResult> act(GroupAction action) async {
    final Map<String, dynamic> json;
    try {
      json = await _network.run(
        () => _remoteDataSource.groupChallengeAct(
          action: action.operation,
          requestId: action.requestId,
          challengeId: action.challengeId,
          questId: action.questId,
          progress: action.progressValue,
        ),
      );
    } on NoNetworkException {
      throw const GroupActionNotSentException();
    } on PostgrestException catch (e) {
      throw AppException(_postgrestMessage(e));
    } catch (_) {
      // SocketException, http.ClientException, TimeoutException (postgrest
      // rethrows them unwrapped): the request may have arrived.
      throw const GroupActionUnconfirmedException();
    }
    try {
      return GroupActionResult.fromJson(json);
    } catch (_) {
      throw const AppException('El servidor respondió algo inesperado. Inténtalo de nuevo.');
    }
  }

  GroupAction? pendingAction() {
    try {
      final saved = _localDataSource.getPendingGroupAction();
      return saved == null ? null : GroupAction.fromJson(saved);
    } catch (_) {
      return null;
    }
  }

  Future<void> savePendingAction(GroupAction? action) async {
    try {
      await _localDataSource.savePendingGroupAction(action?.toJson());
    } catch (error) {
      // Still kept in memory for this visit.
      debugPrint('Group challenges: pending request not saved ($error)');
    }
  }

  /// PostgREST's messages are English and technical.
  static String _postgrestMessage(PostgrestException e) => switch (e.code) {
    '42501' || 'PGRST301' || 'PGRST303' => 'Tu sesión venció. Cierra sesión y vuelve a entrar.',
    'PGRST202' => 'El servidor todavía no tiene retos en grupo.',
    _ => 'El servidor no pudo completar la solicitud.',
  };
}
