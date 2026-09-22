import 'package:flutter/foundation.dart';

import '../../core/app_exception.dart';
import '../../repository/social_repository.dart';

/// Social feed, friends, friend requests and group challenges.
/// Backed by [SocialRepository], which is a stub until the backend adds
/// friends/group-challenge tables and enables Realtime.
class SocialViewModel extends ChangeNotifier {
  final SocialRepository _socialRepository;

  bool isLoading = false;
  String? errorMessage;

  SocialViewModel(this._socialRepository);

  Future<void> load() async {
    isLoading = true;
    errorMessage = null;
    notifyListeners();
    try {
      await _socialRepository.getFriends();
    } on AppException catch (e) {
      errorMessage = e.message;
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }
}
