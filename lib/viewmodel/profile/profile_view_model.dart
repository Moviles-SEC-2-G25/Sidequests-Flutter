import 'package:flutter/foundation.dart';

import '../../core/app_exception.dart';
import '../../models/profile.dart';
import '../../models/user_preferences.dart';
import '../../repository/profile_repository.dart';

/// Preferences, achievements and settings for the profile views.
class ProfileViewModel extends ChangeNotifier {
  final ProfileRepository _profileRepository;
  final String _userId;

  Profile? profile;
  UserPreferences preferences = const UserPreferences();
  bool isLoading = false;
  String? errorMessage;

  ProfileViewModel(this._profileRepository, this._userId);

  Future<void> load() async {
    isLoading = true;
    errorMessage = null;
    notifyListeners();
    try {
      profile = await _profileRepository.getProfile(_userId);
      preferences = await _profileRepository.getPreferences(_userId);
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
