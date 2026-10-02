import 'dart:io';
import 'dart:typed_data';

import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Local cache: preferences, quest catalog, active quest and progress.
/// Repositories read from here when the network is unavailable and write
/// through on every successful remote fetch. Session persistence is handled
/// by supabase_flutter itself, not duplicated here.
///
/// Structured/larger records live in a Hive box; small standalone flags use
/// SharedPreferences, matching the architecture's Local Data Source stack.
class LocalDataSource {
  static const _boxName = 'sidequests_cache';

  static const _keyPreferences = 'preferences';
  static const _keyQuestCatalog = 'quest_catalog';
  static const _keyUserQuests = 'user_quests';
  static const _keyActiveQuestId = 'active_quest_id';
  static const _keyStepTotals = 'step_totals';
  static const _keyActiveStepSession = 'active_step_session';
  static const _keyPendingPhotoProofs = 'pending_photo_proofs';
  static const _pendingProofsDir = 'pending_proofs';
  static const _keyOnboardingComplete = 'onboarding_complete';
  static const _keyDarkMode = 'dark_mode';
  static const _keyMissionNotifications = 'mission_notifications_enabled';
  static const _keyDailyReminders = 'daily_reminders_enabled';
  static const _keyBiometricEnabled = 'biometric_enabled';

  late final Box _box;
  late final SharedPreferences _prefs;

  Future<void> init() async {
    await Hive.initFlutter();
    _box = await Hive.openBox(_boxName);
    _prefs = await SharedPreferences.getInstance();
  }

  bool hasCompletedOnboarding() =>
      _prefs.getBool(_keyOnboardingComplete) ?? false;

  Future<void> setCompletedOnboarding(bool value) =>
      _prefs.setBool(_keyOnboardingComplete, value);

  // Device-level display/notification preferences. Kept outside `clear()`
  // since they belong to the device, not the signed-in account.
  bool isDarkMode() => _prefs.getBool(_keyDarkMode) ?? false;

  Future<void> setDarkMode(bool value) => _prefs.setBool(_keyDarkMode, value);

  /// Local preference only — there is no push-notification backend yet
  /// (Firebase Cloud Messaging and the `notify` edge function are both
  /// {planned} in Sidequests-Backend), so this stores intent without
  /// triggering any real notification.
  bool missionNotificationsEnabled() =>
      _prefs.getBool(_keyMissionNotifications) ?? true;

  Future<void> setMissionNotificationsEnabled(bool value) =>
      _prefs.setBool(_keyMissionNotifications, value);

  bool dailyRemindersEnabled() => _prefs.getBool(_keyDailyReminders) ?? false;

  Future<void> setDailyRemindersEnabled(bool value) =>
      _prefs.setBool(_keyDailyReminders, value);

  /// Account-bound: cleared on sign-out so the next account starts without
  /// a biometric lock it never enabled.
  bool isBiometricEnabled() => _prefs.getBool(_keyBiometricEnabled) ?? false;

  Future<void> setBiometricEnabled(bool value) =>
      _prefs.setBool(_keyBiometricEnabled, value);

  Map<String, dynamic>? getPreferences() =>
      (_box.get(_keyPreferences) as Map?)?.cast<String, dynamic>();

  Future<void> cachePreferences(Map<String, dynamic> preferences) =>
      _box.put(_keyPreferences, preferences);

  List<Map<String, dynamic>> getQuestCatalog() =>
      (_box.get(_keyQuestCatalog) as List? ?? const [])
          .cast<Map>()
          .map((quest) => quest.cast<String, dynamic>())
          .toList();

  Future<void> cacheQuestCatalog(List<Map<String, dynamic>> quests) =>
      _box.put(_keyQuestCatalog, quests);

  List<Map<String, dynamic>> getUserQuests() =>
      (_box.get(_keyUserQuests) as List? ?? const [])
          .cast<Map>()
          .map((userQuest) => userQuest.cast<String, dynamic>())
          .toList();

  Future<void> cacheUserQuests(List<Map<String, dynamic>> userQuests) =>
      _box.put(_keyUserQuests, userQuests);

  String? getActiveQuestId() => _box.get(_keyActiveQuestId) as String?;

  Future<void> cacheActiveQuestId(String? questId) =>
      _box.put(_keyActiveQuestId, questId);

  /// Walked steps per quest attempt (`user_quests.id`). Local-only — the
  /// backend has no steps column — and, like the rest of the box, cleared
  /// on sign-out.
  Map<String, int> getStepTotals() => (_box.get(_keyStepTotals) as Map? ?? const {}).map(
    (key, value) => MapEntry(key as String, (value as num).toInt()),
  );

  Future<void> saveStepTotal(String userQuestId, int steps) =>
      _box.put(_keyStepTotals, {...getStepTotals(), userQuestId: steps});

  /// The step session being counted right now, so an app restart mid-
  /// mission keeps its baseline (and the steps walked while closed).
  Map<String, dynamic>? getActiveStepSession() =>
      (_box.get(_keyActiveStepSession) as Map?)?.cast<String, dynamic>();

  Future<void> saveActiveStepSession(Map<String, dynamic>? session) => session == null
      ? _box.delete(_keyActiveStepSession)
      : _box.put(_keyActiveStepSession, session);

  /// Photos captured but not uploaded yet (Retry tactic). Only metadata
  /// lives in Hive; the JPEG bytes are files in the app documents folder —
  /// not image_picker's cache, which the OS may clear at any time.
  List<Map<String, dynamic>> getPendingPhotoProofs() =>
      (_box.get(_keyPendingPhotoProofs) as List? ?? const [])
          .cast<Map>()
          .map((proof) => proof.cast<String, dynamic>())
          .toList();

  Future<void> savePendingPhotoProofs(List<Map<String, dynamic>> proofs) =>
      _box.put(_keyPendingPhotoProofs, proofs);

  Future<String> writePendingProofFile(String fileName, Uint8List bytes) async {
    final dir = await _pendingProofsDirectory();
    final file = File('${dir.path}/$fileName');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  Future<Uint8List?> readPendingProofFile(String path) async {
    final file = File(path);
    return await file.exists() ? file.readAsBytes() : null;
  }

  Future<void> deletePendingProofFile(String path) async {
    final file = File(path);
    if (await file.exists()) await file.delete();
  }

  Future<Directory> _pendingProofsDirectory() async {
    final documents = await getApplicationDocumentsDirectory();
    return Directory('${documents.path}/$_pendingProofsDir').create(recursive: true);
  }

  /// Clears the cache on sign-out so the next account never sees stale data.
  Future<void> clear() async {
    // Pending photos belong to the account signing out; without their
    // metadata (cleared below) the files could never be uploaded anyway.
    try {
      final dir = await _pendingProofsDirectory();
      await dir.delete(recursive: true);
    } catch (_) {
      // Nothing to clean, or no documents folder on this platform.
    }
    await _box.clear();
    await _prefs.remove(_keyOnboardingComplete);
    await _prefs.remove(_keyBiometricEnabled);
  }
}
