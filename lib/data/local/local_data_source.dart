import 'package:hive_flutter/hive_flutter.dart';
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
  static const _keyOnboardingComplete = 'onboarding_complete';

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

  /// Clears the cache on sign-out so the next account never sees stale data.
  Future<void> clear() async {
    await _box.clear();
    await _prefs.remove(_keyOnboardingComplete);
  }
}
