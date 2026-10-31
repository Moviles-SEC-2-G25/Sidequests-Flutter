import 'package:flutter/foundation.dart';

import '../../core/app_exception.dart';
import '../../models/profile.dart';
import '../../models/user_preferences.dart';
import '../../repository/auth_repository.dart';
import '../../repository/profile_repository.dart';

/// Preferences, achievements and settings for the profile views.
class ProfileViewModel extends ChangeNotifier {
  final ProfileRepository _profileRepository;
  final AuthRepository _authRepository;
  final String _userId;

  Profile? profile;
  UserPreferences preferences = const UserPreferences();
  bool isLoading = false;
  String? errorMessage;

  ProfileViewModel(this._profileRepository, this._authRepository, this._userId);

  String? get email => _authRepository.currentUserEmail;

  Future<void> load() async {
    isLoading = true;
    errorMessage = null;
    notifyListeners();
    try {
      // At once, so a stalled network costs one timeout and not one per read.
      // Each result is kept as it arrives, so one failing doesn't lose the other.
      await Future.wait([
        _profileRepository.getProfile(_userId).then((loaded) => profile = loaded),
        _profileRepository.getPreferences(_userId).then((loaded) => preferences = loaded),
      ]);
    } on AppException catch (e) {
      errorMessage = e.message;
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> updatePreferences(UserPreferences updated) async {
    try {
      await _profileRepository.updatePreferences(_userId, updated);
      preferences = updated;
      notifyListeners();
      return true;
    } on AppException catch (e) {
      errorMessage = e.message;
      notifyListeners();
      return false;
    }
  }
}
