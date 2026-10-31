import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Local cache: profile, preferences, quest catalog and steps, the user's
/// attempts and their photo proofs, active quest and progress, analytics
<<<<<<< HEAD
/// events and quest writes waiting for a connection, resolved quest addresses,
/// the last recommendations, and the last weather reading per location.
/// Repositories read from here when the network is unavailable and write
/// through on every successful remote fetch or write. Session persistence
/// is handled by supabase_flutter itself, not duplicated here.
///
/// Structured/larger records live in a Hive box; small standalone flags use
/// SharedPreferences, matching the architecture's Local Data Source stack.
class LocalDataSource {
  static const _boxName = 'sidequests_cache';

  static const _keyProfile = 'profile';
  static const _keyPreferences = 'preferences';
  static const _keyQuestCatalog = 'quest_catalog';
  static const _keyQuestSteps = 'quest_steps';
  static const _keyPhotoProofs = 'photo_proofs';
  static const _keyUserQuests = 'user_quests';
  static const _keyActiveQuestId = 'active_quest_id';
  static const _keyStepTotals = 'step_totals';
  static const _keyActiveStepSession = 'active_step_session';
  static const _keyPendingPhotoProofs = 'pending_photo_proofs';
  static const _pendingProofsDir = 'pending_proofs';
  static const _keyPendingAnalyticsEvents = 'pending_analytics_events';
  static const _keyPendingWrites = 'pending_writes';
  static const _keySavedRecommendations = 'saved_recommendations';
  static const _keyAddresses = 'addresses';
  static const _keyWeatherSnapshots = 'weather_snapshots';
  static const _keyOnboardingComplete = 'onboarding_complete';
  static const _keyDarkMode = 'dark_mode';
  static const _keyExploreFilters = 'explore_filters';
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

  /// Explore's last filters; null until the user changes one.
  Map<String, dynamic>? getExploreFilters() {
    final saved = _prefs.getString(_keyExploreFilters);
    return saved == null ? null : jsonDecode(saved) as Map<String, dynamic>;
  }

  Future<void> saveExploreFilters(Map<String, dynamic> filters) =>
      _prefs.setString(_keyExploreFilters, jsonEncode(filters));

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
  /// a biometric lock it never enabled. Lives only in SharedPreferences, never
  /// on the backend, so it reads and writes the same offline.
  bool isBiometricEnabled() => _prefs.getBool(_keyBiometricEnabled) ?? false;

  Future<void> setBiometricEnabled(bool value) =>
      _prefs.setBool(_keyBiometricEnabled, value);

  Map<String, dynamic>? getProfile() =>
      (_box.get(_keyProfile) as Map?)?.cast<String, dynamic>();

  Future<void> cacheProfile(Map<String, dynamic> profile) =>
      _box.put(_keyProfile, profile);

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

  /// Steps of [questId]; null when that quest was never opened online.
  List<Map<String, dynamic>>? getQuestSteps(String questId) =>
      _getRowsFor(_keyQuestSteps, questId);

  Future<void> cacheQuestSteps(String questId, List<Map<String, dynamic>> steps) =>
      _putRowsFor(_keyQuestSteps, questId, steps);

  /// Registered photo proofs of one attempt (`user_quests.id`); null when
  /// they were never fetched online.
  List<Map<String, dynamic>>? getPhotoProofs(String attemptId) =>
      _getRowsFor(_keyPhotoProofs, attemptId);

  Future<void> cachePhotoProofs(String attemptId, List<Map<String, dynamic>> proofs) =>
      _putRowsFor(_keyPhotoProofs, attemptId, proofs);

  /// Rows stored per id under one key, so "nothing cached for this id"
  /// (null) stays distinct from "cached, and empty".
  List<Map<String, dynamic>>? _getRowsFor(String key, String id) =>
      ((_box.get(key) as Map?)?[id] as List?)
          ?.cast<Map>()
          .map((row) => row.cast<String, dynamic>())
          .toList();

  Future<void> _putRowsFor(String key, String id, List<Map<String, dynamic>> rows) =>
      _box.put(key, {...(_box.get(key) as Map? ?? const {}), id: rows});

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

  /// False on the web build: there's no app documents folder (dart:io
  /// files / path_provider) to keep a photo in until it's uploaded.
  bool get canKeepPhotoFiles => !kIsWeb;

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

  /// Analytics events whose insert failed for lack of connection, oldest
  /// first (store-and-forward), each exactly as it was built. Cleared on
  /// sign-out with the rest of the box: the backend stamps `user_id` from
  /// the session at insert time, so they must not outlive their account.
  List<Map<String, dynamic>> getPendingAnalyticsEvents() =>
      (_box.get(_keyPendingAnalyticsEvents) as List? ?? const [])
          .cast<Map>()
          .map((event) => event.cast<String, dynamic>())
          .toList();

  Future<void> savePendingAnalyticsEvents(List<Map<String, dynamic>> events) =>
      _box.put(_keyPendingAnalyticsEvents, events);

  /// Quest writes waiting for a connection, oldest first (see PendingWrite).
  /// Cleared on sign-out with the rest of the box.
  List<Map<String, dynamic>> getPendingWrites() =>
      (_box.get(_keyPendingWrites) as List? ?? const [])
          .cast<Map>()
          .map((write) => write.cast<String, dynamic>())
          .toList();

  Future<void> savePendingWrites(List<Map<String, dynamic>> writes) =>
      _box.put(_keyPendingWrites, writes);

  /// The last recommendations received and their batch id; null until one
  /// non-empty list arrives online.
  ({String batchId, List<Map<String, dynamic>> rows})? getSavedRecommendations() {
    final saved = _box.get(_keySavedRecommendations) as Map?;
    if (saved == null) return null;
    return (
      batchId: saved['batch_id'] as String,
      rows: (saved['rows'] as List)
          .cast<Map>()
          .map((row) => row.cast<String, dynamic>())
          .toList(),
    );
  }

  Future<void> saveRecommendations(String batchId, List<Map<String, dynamic>> rows) =>
      _box.put(_keySavedRecommendations, {'batch_id': batchId, 'rows': rows});

  /// Reverse-geocoded address of [coordinatesKey]; null when it was never
  /// resolved online.
  String? getAddress(String coordinatesKey) =>
      (_box.get(_keyAddresses) as Map?)?[coordinatesKey] as String?;

  Future<void> cacheAddress(String coordinatesKey, String address) => _box.put(
    _keyAddresses,
    {...(_box.get(_keyAddresses) as Map? ?? const {}), coordinatesKey: address},
  );

  /// Last weather reading of [coordinatesKey]; null when none was ever
  /// fetched online.
  Map<String, dynamic>? getWeatherSnapshot(String coordinatesKey) =>
      ((_box.get(_keyWeatherSnapshots) as Map?)?[coordinatesKey] as Map?)?.cast<String, dynamic>();

  Future<void> cacheWeatherSnapshot(String coordinatesKey, Map<String, dynamic> snapshot) => _box.put(
    _keyWeatherSnapshots,
    {...(_box.get(_keyWeatherSnapshots) as Map? ?? const {}), coordinatesKey: snapshot},
  );

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
