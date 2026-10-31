import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../analytics/analytics_event_type.dart';
import '../../analytics/analytics_tracker.dart';
import '../../core/app_exception.dart';
import '../../core/bq10_context.dart';
import '../../core/bq6_evidence.dart';
import '../../core/completion_likelihood.dart';
import '../../core/quest_alternative_recommender.dart';
import '../../core/similar_quest_recommender.dart';
import '../../core/verification/step_verification_strategy.dart';
import '../../core/verification/verification_strategies.dart';
import '../../data/context/context_manager.dart';
import '../../data/remote/network_guard.dart';
import '../../data/services/location_check_in_service.dart';
import '../../data/services/photo_capture_service.dart';
import '../../data/services/step_counter_service.dart';
import '../../models/abandonment_reason.dart';
import '../../models/app_context.dart';
import '../../models/explore_filters.dart';
import '../../models/photo_proof.dart';
import '../../models/quest.dart';
import '../../models/quest_recommendation.dart';
import '../../models/quest_step.dart';
import '../../models/step_session.dart';
import '../../models/user_preferences.dart';
import '../../models/user_quest.dart';
import '../../models/verified_check_in.dart';
import '../../repository/quest_repository.dart';

const List<int> kAvailableMinuteOptions = [10, 20, 30, 45, 60];

/// A mission being actively done: it can be resumed from the Explore "continue"
/// banner or the Misión tab, walked steps are counted and the GPS check-in
/// runs. An abandoned attempt is closed, as in Kotlin: starting that quest again
/// is a new attempt.
const _activeMissionStatuses = {'accepted', 'in_progress'};

/// Minimum time between two automatic check-in attempts on the same step,
/// so a failing update (offline) isn't retried on every GPS fix.
const _autoCheckInRetryInterval = Duration(seconds: 30);

/// How many new steps between two writes of the active step session to
/// Hive — enough to survive an app kill without writing on every reading.
const _stepPersistInterval = 25;

/// One automatic location check-in, for HomeShell to announce.
class CheckInEvent {
  /// The attempt as it was before the step was completed.
  final UserQuest mission;
  final Quest quest;
  final bool completedQuest;

  const CheckInEvent({required this.mission, required this.quest, required this.completedQuest});
}

/// The alternatives offered after abandoning a mission.
class QuestAlternativesState {
  final String sourceQuestId;
  final String sourceAttemptId;
  final AbandonmentReason reason;
  final bool isLoading;
  final List<QuestAlternative> suggestions;

  /// What [suggestions] were computed with; null until the first load ends.
  final AppContext? context;

  const QuestAlternativesState({
    required this.sourceQuestId,
    required this.sourceAttemptId,
    required this.reason,
    this.isLoading = true,
    this.suggestions = const [],
    this.context,
  });

  String? get weatherCondition =>
      context == null ? null : alternativesWeatherCondition(context!);
}

/// Explore, nearby, quest detail and mission-in-progress state.
class QuestViewModel extends ChangeNotifier {
  final QuestRepository _questRepository;
  final ContextManager _contextManager;
  final AnalyticsTracker _analyticsTracker;
  final String _userId;
  final SimilarQuestRecommender _similarQuestRecommender;
  final CompletionLikelihood _completionLikelihood;
  final StepCounterService _stepCounter;
  late final StreamSubscription<void> _stepCounterSubscription;
  int? _lastPersistedSteps;
  final LocationCheckInService _checkIn;
  StreamSubscription<CheckInFix>? _checkInSubscription;
  final StreamController<CheckInEvent> _checkInEvents = StreamController<CheckInEvent>.broadcast();
  final StreamController<void> _exploreTabRequests = StreamController<void>.broadcast();
  final _questAlternativeRecommender = const QuestAlternativeRecommender();

  /// Abandonments on their way, by attempt: a repeated tap gets the same one.
  final Map<String, Future<bool>> _abandonsInFlight = {};

  /// Bumped on every load and on leaving, so a late result is dropped.
  int _alternativesGeneration = 0;

  /// `"<user_quests.id>:<currentStep>"` of the step whose location is being
  /// watched; null when the GPS is off.
  String? _checkInKey;
  VerificationEvidence _evidence = const VerificationEvidence();
  bool _isForeground = true;
  bool _isCompletingStep = false;
  DateTime? _lastAutoCheckInAt;

  /// In memory what the repository has, so the view can read it on every build.
  VerifiedCheckIn? _savedCheckIn;

  /// The last [completeCurrentStep] failed for lack of a connection, as
  /// opposed to being rejected.
  bool _lastStepFailedForConnection = false;

  final PhotoCaptureService _photoCapture;

  /// Registered proofs (uploaded + recorded) of [_photoProofsAttemptId],
  /// by zero-based step order — the PhotoVerification evidence.
  Map<int, QuestPhotoProof> _photoProofs = {};
  String? _photoProofsAttemptId;

  /// Captured photos still waiting to be uploaded (kept on the device).
  List<PendingPhotoProof> pendingPhotoProofs = [];
  String? _uploadingStoragePath;
  bool isCapturingPhoto = false;

  /// A photo that can't be retried (rejected, invalid): take another one.
  String? photoErrorMessage;

  List<Quest> catalog = [];
  List<QuestRecommendation> recommendations = [];

  /// [recommendations] is the list saved on the device: the network failed.
  bool recommendationsFromCache = false;

  /// The social level of the last list the server answered, which is also the
  /// one saved on the device. null until one arrives this session.
  String? _lastServedSocialLevel;
  List<UserQuest> userQuests = [];
  List<QuestStep> steps = [];
  String? _stepsQuestId;

  /// Steps of a quest other than the active mission, opened in its detail.
  /// Apart from [steps], which the mission keeps using meanwhile.
  ({String questId, List<QuestStep> steps})? _otherQuestSteps;
  ({String questId, String message})? _stepsUnavailable;
  bool isLoading = false;
  bool isLoadingRecommendations = false;
  bool isLoadingSteps = false;
  String? errorMessage;

  /// The last [startInstantPlan] started on the device, pending sync.
  bool instantPlanQueued = false;
  bool isSubmittingRating = false;
  String? ratingErrorMessage;

  /// The last [submitRating] stayed on the device, pending sync.
  bool ratingQueued = false;

  /// The last [abandonQuest] stayed on the device, pending sync.
  bool abandonmentQueued = false;

  /// The alternatives on screen after abandoning; null when there are none.
  QuestAlternativesState? questAlternatives;

  /// Why the last [completeCurrentStep] couldn't be saved (e.g. offline);
  /// null when it went through or is still running.
  String? stepErrorMessage;

  // Explore's filters: start as the user left them and are saved on change.
  int selectedMinutes;
  String selectedLocationScope; // all | gps | anywhere
  String? selectedCategory; // null = "Todo", 'sponsored', or a real category

  /// "¿Cómo te sientes hoy?" (BQ5): overrides the profile's social level
  /// for this session only — never saved to user_preferences. null = use
  /// UserPreferences.socialLevel.
  String? sessionSocialLevel; // solo | social | group

  final Set<String> _sessionSkippedQuestIds = {};

  double? userLatitude;
  double? userLongitude;
  bool isLocatingUser = false;

  /// Last Context Manager snapshot (location, time of day, weather...),
  /// refreshed whenever recommendations load. Drives Explore's automatic
  /// weather/time-of-day adaptation — null until the first load.
  AppContext? currentContext;

  // --- BQ4: "decision journey" toward starting a quest — how long, and how
  // many interactions, from the first recommendations shown (after opening
  // the app or after the last quest was started) to accepting one. ---
  DateTime? _decisionStartedAt;
  String? _decisionBatchId;
  int _interactionCount = 0;

  /// Batch of the list on screen; it can outlive a journey (see
  /// [onExploreVisible]).
  String? _visibleBatchId;

  /// Where the clock counts from when no list started it: nothing was on
  /// screen, or the quest was started elsewhere.
  DateTime _lastJourneyEndedAt;
  final DateTime Function() _now;

  QuestViewModel(
    this._questRepository,
    this._contextManager,
    this._analyticsTracker,
    this._userId, {
    ExploreFilters initialFilters = const ExploreFilters(),
    SimilarQuestRecommender similarQuestRecommender = const SimilarQuestRecommender(),
    CompletionLikelihood completionLikelihood = const CompletionLikelihood(),
    StepCounterService? stepCounter,
    LocationCheckInService? locationCheckIn,
    PhotoCaptureService? photoCapture,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now,
       _lastJourneyEndedAt = (now ?? DateTime.now)(),
       selectedMinutes = initialFilters.minutes,
       selectedLocationScope = initialFilters.locationScope,
       selectedCategory = initialFilters.category,
       _similarQuestRecommender = similarQuestRecommender,
       _completionLikelihood = completionLikelihood,
       _stepCounter = stepCounter ?? StepCounterService(),
       _checkIn = locationCheckIn ?? LocationCheckInService(),
       _photoCapture = photoCapture ?? PhotoCaptureService() {
    _stepCounterSubscription = _stepCounter.onChange.listen((_) => _onStepCounterChange());
  }

  /// The quest to resume from "Continúa donde lo dejaste" / the Misión tab:
  /// the most recently touched quest still being done. `userQuests` is
  /// already ordered by `updated_at desc` by the repository query.
  UserQuest? get currentMission => userQuests
      .cast<UserQuest?>()
      .firstWhere((uq) => _activeMissionStatuses.contains(uq!.status), orElse: () => null);

  Quest? questById(String id) =>
      catalog.cast<Quest?>().firstWhere((q) => q!.id == id, orElse: () => null);

  List<String> get categories =>
      catalog.map((q) => q.category).toSet().toList()..sort();

  List<Quest> get filteredCatalog {
    final filtered = catalog.where((quest) {
      if (quest.durationMinutes > selectedMinutes) return false;
      if (selectedLocationScope != 'all' && quest.locationMode != selectedLocationScope) {
        return false;
      }
      if (selectedCategory == 'sponsored') return quest.isSponsored;
      if (selectedCategory != null &&
          quest.category.toLowerCase() != selectedCategory!.toLowerCase()) {
        return false;
      }
      return true;
    }).toList();

    if (!isAdaptingToContext) return filtered;

    // Stable partition, not a filter: 'anywhere' quests move first, but
    // nothing is dropped from the list.
    final anywhere = filtered.where((quest) => quest.locationMode == 'anywhere');
    final rest = filtered.where((quest) => quest.locationMode != 'anywhere');
    return [...anywhere, ...rest];
  }

  /// True when it's raining at the user's location or it's nighttime —
  /// Explore then prioritizes 'anywhere' (indoor/no-travel) quests and
  /// shows a banner explaining why.
  bool get isAdaptingToContext =>
      (currentContext?.isRainy ?? false) || currentContext?.timeOfDay == 'night';

  Future<void> load() async {
    isLoading = true;
    errorMessage = null;
    notifyListeners();
    try {
      // Both requests at once. Each result is kept as it arrives, so one
      // failing doesn't lose the other; the first error is rethrown once
      // both have finished.
      await Future.wait([
        _questRepository.getCatalog().then((quests) {
          catalog = quests;
          _dropMissingCategory();
        }),
        _questRepository.getUserQuests(_userId).then((attempts) {
          userQuests = attempts;
        }),
      ]);
      unawaited(_resumeStepTracking());
      unawaited(retryPendingPhotoUploads());
    } on AppException catch (e) {
      errorMessage = e.message;
    } finally {
      isLoading = false;
      _syncCheckIn();
      notifyListeners();
    }
    await _applySavedCheckIn();
  }

  /// A saved category can leave the catalog between launches; keeping it
  /// would show an empty list with no chip selected to explain why. An empty
  /// catalog (offline, nothing cached) says nothing about the category.
  void _dropMissingCategory() {
    final category = selectedCategory;
    if (category == null || category == 'sponsored' || catalog.isEmpty) return;
    if (categories.contains(category)) return;
    selectedCategory = null;
    _saveFilters();
  }

  void _saveFilters() => unawaited(
    _questRepository.saveExploreFilters(
      ExploreFilters(
        minutes: selectedMinutes,
        locationScope: selectedLocationScope,
        category: selectedCategory,
      ),
    ),
  );

  void setMinutes(int minutes) {
    selectedMinutes = minutes;
    _saveFilters();
    registerInteraction();
    notifyListeners();
  }

  void setCategory(String? category) {
    selectedCategory = category;
    _saveFilters();
    registerInteraction();
    notifyListeners();
  }

  /// Counts as a BQ4 browsing interaction, like the other Explore filters.
  /// The caller reloads recommendations, as with setMinutes/setLocationScope.
  void setSessionSocialLevel(String level) {
    sessionSocialLevel = level;
    registerInteraction();
    notifyListeners();
  }

  /// The social level recommend_quests actually gets: the session override
  /// if the user picked one, else the profile's.
  String effectiveSocialLevel(UserPreferences profile) =>
      sessionSocialLevel ?? profile.socialLevel;

  /// The chip the saved list on screen doesn't reflect yet: the server applies
  /// it when [refreshAfterReconnect] reloads. null when there's nothing to wait
  /// for, like a chip picked online whose own list is the one saved.
  String? get socialLevelAwaitingReconnect {
    final level = sessionSocialLevel;
    return recommendationsFromCache && level != _lastServedSocialLevel ? level : null;
  }

  /// BQ10 (location-independent mode usage) is measured from the 'anywhere'
  /// and 'gps' events; 'all' isn't part of it. Its context metadata comes
  /// from the last snapshot ([currentContext]).
  void setLocationScope(String scope) {
    selectedLocationScope = scope;
    _saveFilters();
    registerInteraction();
    notifyListeners();
    final bq10EventType = switch (scope) {
      'anywhere' => AnalyticsEventType.locationIndependentModeSelected,
      'gps' => AnalyticsEventType.locationBasedModeSelected,
      _ => null,
    };
    _analyticsTracker.track(
      bq10EventType ?? AnalyticsEventType.locationModeSelected,
      locationMode: scope,
      metadata: bq10EventType == null
          ? const {}
          : bq10Metadata(scope, currentContext, DateTime.now()),
    );
  }

  /// BQ4: counts one step of browsing toward the decision to start a quest —
  /// a filter change, dismissing a recommendation, or opening a quest's
  /// detail from Explore. The final "accept" tap itself isn't counted.
  void registerInteraction() {
    _interactionCount++;
  }

  Future<void> loadRecommendations(UserPreferences preferences) async {
    isLoadingRecommendations = true;
    notifyListeners();
    try {
      final context = await _contextWithinLimit();
      currentContext = context;
      final effectivePreferences = preferences.copyWith(
        locationMode: selectedLocationScope,
        socialLevel: sessionSocialLevel,
      );
      final batch = await _questRepository.getRecommendations(
        context: context,
        preferences: effectivePreferences,
        excludedQuestIds: _sessionSkippedQuestIds.toList(),
      );
      recommendations = batch.recommendations;
      recommendationsFromCache = batch.fromCache;
      // One batch_id per RPC call so BQ8 can group the events of one list.
      final batchId = batch.batchId;
      // BQ4: starts the decision clock on the first non-empty list shown
      // since the app opened (or since the last quest was started) — later
      // reloads (filter changes, "Ahora no") don't restart it.
      if (recommendations.isNotEmpty) {
        _decisionStartedAt ??= _now();
        _decisionBatchId ??= batchId;
        _visibleBatchId = batchId;
      }
      // A saved list logged its impressions when it was first shown (BQ8).
      if (batch.fromCache) return;
      _lastServedSocialLevel = effectivePreferences.socialLevel;
      for (final recommendation in recommendations) {
        _analyticsTracker.track(
          AnalyticsEventType.recommendationShown,
          questId: recommendation.questId,
          category: recommendation.category,
          availableMinutes: selectedMinutes,
          socialLevel: effectivePreferences.socialLevel,
          locationMode: selectedLocationScope,
          metadata: {
            'variant': recommendation.variant,
            'rank': recommendation.rankPosition,
            'batch_id': batchId,
            'social_level_source': sessionSocialLevel != null ? 'session' : 'profile',
          },
        );
      }
    } on AppException catch (e) {
      errorMessage = e.message;
    } finally {
      isLoadingRecommendations = false;
      notifyListeners();
    }
  }

  /// The GPS alone can take 10 s, and recommend_quests doesn't use the position.
  /// Past the limit Explore goes on with what the device knows on its own (the
  /// time of day), and the full reading replaces it when it arrives.
  Future<AppContext> _contextWithinLimit() async {
    final reading = _contextManager.snapshot(availableMinutes: selectedMinutes);
    try {
      return await reading.timeout(NetworkGuard.timeout);
    } on TimeoutException {
      unawaited(
        reading.then(
          (context) {
            currentContext = context;
            notifyListeners();
          },
          onError: (Object _) {},
        ),
      );
      return _contextManager.localSnapshot(availableMinutes: selectedMinutes);
    }
  }

  /// When the catalog already fell back to the cache there's no point making
  /// Explore wait for another request to show the saved list. Logs nothing: it
  /// logged its impressions when it was first shown (BQ8).
  void showSavedRecommendationsIfOffline() {
    if (recommendations.isNotEmpty || !_questRepository.catalogFromCache) return;
    final saved = _questRepository.savedRecommendations(_sessionSkippedQuestIds.toList());
    if (saved == null || saved.recommendations.isEmpty) return;
    recommendations = saved.recommendations;
    recommendationsFromCache = true;
    _decisionStartedAt ??= _now();
    _decisionBatchId ??= saved.batchId;
    _visibleBatchId = saved.batchId;
    notifyListeners();
  }

  /// The user is back on Explore with the list from before starting a quest:
  /// that's where the next decision journey starts, since no new list will.
  void onExploreVisible() {
    if (_decisionStartedAt != null || recommendations.isEmpty) return;
    _decisionStartedAt = _now();
    _decisionBatchId = _visibleBatchId;
  }

  /// Just the context (weather, time of day), so Explore can adapt again
  /// without asking for recommendations or logging anything. On failure the
  /// last one stays.
  Future<void> refreshContext() async {
    try {
      currentContext = await _contextManager.snapshot(availableMinutes: selectedMinutes);
      notifyListeners();
    } catch (_) {
      // A missing sensor: nothing new to adapt to.
    }
  }

  /// Back online. Recommendations reload only when Explore has nothing to show
  /// or only the saved list (it failed offline): reloading a live list the user
  /// already has would log recommendation_shown again for a list they may not
  /// even be looking at (BQ8 impressions). Either way the context is read again,
  /// which replaces a last known weather with a real one.
  Future<void> refreshAfterReconnect(UserPreferences preferences) async {
    await load();
    if (recommendations.isEmpty || recommendationsFromCache) {
      await loadRecommendations(preferences);
    } else {
      await refreshContext();
    }
  }

  /// [wasRecommended] also picks BQ4's start_path: 'standard' from a
  /// recommendation's detail view, 'catalog' from "Todas las misiones".
  /// Returns false (with [errorMessage] set) when it couldn't be saved.
  Future<bool> acceptQuest(String questId, {bool wasRecommended = false}) {
    return _acceptQuest(
      questId,
      startPath: wasRecommended ? 'standard' : 'catalog',
      wasRecommended: wasRecommended,
    );
  }

  /// "Empezar ya" on a recommendation card (BQ4's 'instant_plan' start
  /// path): accepts the quest and preloads its steps, skipping
  /// QuestDetailView entirely. The caller navigates to MissionTabView once
  /// this returns true. Without a connection the mission starts anyway, on
  /// the device: see [instantPlanQueued].
  Future<bool> startInstantPlan(Quest quest) async {
    instantPlanQueued = false;
    final started = await _acceptQuest(
      quest.id,
      startPath: 'instant_plan',
      wasRecommended: true,
      canQueue: true,
    );
    if (!started) return false;
    // Queued: the network already failed, and the steps are known to be saved.
    await loadSteps(quest.id, cacheOnly: instantPlanQueued);
    return true;
  }

  Future<bool> _acceptQuest(
    String questId, {
    required String startPath,
    required bool wasRecommended,
    bool canQueue = false,
  }) async {
    try {
      final UserQuest userQuest;
      if (canQueue) {
        final result = await _questRepository.acceptQuestOrQueue(userId: _userId, questId: questId);
        userQuest = result.userQuest;
        instantPlanQueued = result.queued;
        if (result.alreadyStarted) {
          // Same mission, not a new start (BQ4: exactly one event per start).
          _replaceUserQuest(userQuest);
          return true;
        }
      } else {
        userQuest = await _questRepository.acceptQuest(userId: _userId, questId: questId);
      }
      _replaceUserQuest(userQuest);
      // Not awaited: the permission dialog shows over the Misión screen
      // instead of holding up the navigation to it.
      unawaited(_startStepTracking(userQuest));
      final quest = questById(questId);
      // BQ4: how much a ready-to-execute plan (vs. browsing the detail page)
      // shortens the trip from seeing recommendations to starting a quest.
      final secondsToStart = _now().difference(_decisionStartedAt ?? _lastJourneyEndedAt).inSeconds;
      _analyticsTracker.track(
        wasRecommended
            ? AnalyticsEventType.recommendationAccepted
            : AnalyticsEventType.questStarted,
        questId: questId,
        category: quest?.category,
        questDurationMinutes: quest?.durationMinutes,
        questDifficulty: quest?.difficulty,
        estimatedCost: quest?.estimatedCost,
        metadata: {
          'start_path': startPath,
          'seconds_to_start': secondsToStart,
          'interactions_to_start': _interactionCount,
          'batch_id': _decisionBatchId ?? (recommendations.isEmpty ? null : _visibleBatchId),
        },
      );
      _resetDecisionJourney();
      return true;
    } on AppException catch (e) {
      errorMessage = e.message;
      notifyListeners();
      return false;
    }
  }

  /// A new decision journey starts the next time recommendations are shown, or
  /// when the user returns to the ones still on screen ([onExploreVisible]).
  void _resetDecisionJourney() {
    _decisionStartedAt = null;
    _decisionBatchId = null;
    _interactionCount = 0;
    _lastJourneyEndedAt = _now();
  }

  /// "Ahora no" on a recommendation card: excludes it from this session's
  /// recommendations (migration 007's `p_excluded_quest_ids`) and refreshes.
  Future<void> skipRecommendation(String questId, UserPreferences preferences) async {
    _sessionSkippedQuestIds.add(questId);
    recommendations = recommendations.where((r) => r.questId != questId).toList();
    registerInteraction();
    notifyListeners();
    _analyticsTracker.track(
      AnalyticsEventType.recommendationSkipped,
      questId: questId,
      availableMinutes: selectedMinutes,
      locationMode: selectedLocationScope,
    );
    await loadRecommendations(preferences);
  }

  /// Real GPS capture (via the Context Manager's location snapshot) for the
  /// Cerca tab's distance sort. Not persisted — purely for this session's
  /// display, matching the Figma "Activar ubicación" affordance.
  Future<void> requestUserLocation() async {
    isLocatingUser = true;
    notifyListeners();
    final context = await _contextManager.snapshot();
    userLatitude = context.latitude;
    userLongitude = context.longitude;
    isLocatingUser = false;
    notifyListeners();
  }

  /// [questId]'s steps, once loaded; [steps] alone may belong to another quest.
  List<QuestStep> stepsOf(String questId) {
    if (_stepsQuestId == questId) return isLoadingSteps ? const [] : steps;
    return _otherQuestSteps?.questId == questId ? _otherQuestSteps!.steps : const [];
  }

  /// Why [questId]'s steps couldn't load: no connection and none cached.
  String? stepsUnavailableMessage(String questId) =>
      _stepsUnavailable?.questId == questId ? _stepsUnavailable?.message : null;

  /// [steps] always belongs to the active mission when there is one: it's what
  /// the Misión tab shows, the GPS check-in watches and [completeCurrentStep]
  /// counts, so opening another quest's detail must not replace it.
  /// A failure leaves [steps] and [_stepsQuestId] as they were.
  /// [cacheOnly] skips the network, for when it's already known to be down.
  Future<void> loadSteps(String questId, {bool cacheOnly = false}) async {
    final mission = currentMission;
    if (mission != null && mission.questId != questId) return _loadOtherQuestSteps(questId);

    final previousQuestId = _stepsQuestId;
    isLoadingSteps = true;
    _stepsQuestId = questId;
    _stepsUnavailable = null;
    notifyListeners();
    try {
      steps = cacheOnly
          ? await _questRepository.getCachedSteps(questId)
          : await _questRepository.getSteps(questId);
    } on AppException catch (e) {
      errorMessage = e.message;
      if (e.isRetryable) _stepsUnavailable = (questId: questId, message: e.message);
      if (_stepsQuestId == questId) _stepsQuestId = previousQuestId;
    } finally {
      isLoadingSteps = false;
      _syncCheckIn();
      notifyListeners();
      unawaited(_refreshPhotoProofs());
    }
  }

  Future<void> _loadOtherQuestSteps(String questId) async {
    _otherQuestSteps = null;
    _stepsUnavailable = null;
    notifyListeners();
    try {
      _otherQuestSteps = (questId: questId, steps: await _questRepository.getSteps(questId));
    } on AppException catch (e) {
      errorMessage = e.message;
      if (e.isRetryable) _stepsUnavailable = (questId: questId, message: e.message);
    }
    notifyListeners();
  }

  /// Advances the current step (or completes the quest on the last one).
  /// Transitions 'accepted' -> 'in_progress' on the first step so the
  /// backend's lifecycle trigger stamps `started_at` for real.
  /// Returns true only when this call completed the whole quest; when it
  /// couldn't be saved, [stepErrorMessage] says why.
  ///
  /// Shared by the "Completar" button and the automatic location check-in;
  /// [isCompletingStep] keeps the two from advancing the same step twice.
  Future<bool> completeCurrentStep(UserQuest userQuest) async {
    stepErrorMessage = null;
    if (_isCompletingStep) return false;
    _isCompletingStep = true;
    _lastStepFailedForConnection = false;
    notifyListeners();

    final nextCompleted = [...userQuest.completedSteps, userQuest.currentStep];
    final isLastStep = _stepsQuestId == userQuest.questId &&
        userQuest.currentStep >= steps.length - 1;

    try {
      final UserQuest updated;
      if (isLastStep) {
        updated = await _questRepository.completeQuest(
          userQuest.copyWithProgress(completedSteps: nextCompleted),
        );
        final quest = questById(userQuest.questId);
        _analyticsTracker.track(
          AnalyticsEventType.questCompleted,
          questId: updated.questId,
          category: quest?.category,
          questDurationMinutes: quest?.durationMinutes,
          questDifficulty: quest?.difficulty,
        );
      } else {
        updated = await _questRepository.updateProgress(
          userQuest.copyWithProgress(
            status: 'in_progress',
            currentStep: userQuest.currentStep + 1,
            completedSteps: nextCompleted,
          ),
        );
      }
      _replaceUserQuest(updated);
      if (isLastStep) {
        await _finishStepTracking(updated.id);
      }
      return isLastStep;
    } on AppException catch (e) {
      stepErrorMessage = e.message;
      _lastStepFailedForConnection = e.isRetryable;
      return false;
    } finally {
      _isCompletingStep = false;
      notifyListeners();
    }
  }

  /// Saves the post-mission rating/feedback and emits 'quest_rated'.
  /// Returns true on success — also when it was left on the device for later,
  /// see [ratingQueued]; on failure `ratingErrorMessage` is set.
  Future<bool> submitRating(
    UserQuest userQuest, {
    required int rating,
    required List<String> tags,
  }) async {
    isSubmittingRating = true;
    ratingErrorMessage = null;
    ratingQueued = false;
    notifyListeners();
    try {
      final result = await _questRepository.rateQuestOrQueue(userQuest, rating, tags);
      final updated = result.userQuest;
      ratingQueued = result.queued;
      _replaceUserQuest(updated);
      final quest = questById(updated.questId);
      _analyticsTracker.track(
        AnalyticsEventType.questRated,
        questId: updated.questId,
        category: quest?.category,
        questDurationMinutes: quest?.durationMinutes,
        questDifficulty: quest?.difficulty,
        metadata: {'rating': rating, 'tags': tags},
      );
      return true;
    } on AppException catch (e) {
      ratingErrorMessage = e.message;
      return false;
    } finally {
      isSubmittingRating = false;
      notifyListeners();
    }
  }

  /// A new QuestCompletedView shouldn't open with the last one's error. Doesn't
  /// notify: it runs while that view is being built, and it's the only reader.
  void clearRatingError() => ratingErrorMessage = null;

  /// "Te podría gustar" on QuestCompletedView. Pure recomputation from
  /// [rating] each call (no caching), so the view just re-invokes it as the
  /// user picks a star rating, before saving — no separate "recalculate"
  /// step needed.
  List<Quest> similarQuests({required Quest completed, required int rating}) =>
      _similarQuestRecommender.recommend(completed, catalog, userQuests, rating, selectedMinutes);

  /// "Probabilidad de que la termines" on Explore's cards, per category.
  /// Recomputed on every read (no caching) — Explore reads it once per
  /// section build and hands each card its level, so completing or
  /// abandoning a quest updates the labels on the next notifyListeners().
  Map<String, CompletionLevel> get completionLikelihoodByCategory =>
      _completionLikelihood.byCategory(catalog, userQuests);

  /// The labels above were computed from data saved on the device, because the
  /// catalog or the attempts couldn't be fetched.
  bool get completionLabelsFromCache =>
      _questRepository.catalogFromCache || _questRepository.userQuestsFromCache;

  CompletionLevel completionLevelFor(Quest quest, Map<String, CompletionLevel> byCategory) =>
      _completionLikelihood.levelFor(quest, byCategory);

  void trackSimilarQuestOpened({
    required String openedQuestId,
    required String sourceQuestId,
    required int rank,
  }) {
    _analyticsTracker.track(
      AnalyticsEventType.similarQuestOpened,
      questId: openedQuestId,
      metadata: {'source_quest_id': sourceQuestId, 'rank': rank},
    );
  }

  /// Closes the attempt and starts loading its [questAlternatives]; without a
  /// connection it stays on the device, pending sync ([abandonmentQueued]).
  /// Repeated taps get the same answer, with one write and one event.
  /// Returns false (with [errorMessage] set) when it couldn't be saved even
  /// there, so the mission is still active and nothing is tracked.
  Future<bool> abandonQuest(
    UserQuest userQuest, {
    required AbandonmentReason reason,
    UserPreferences preferences = const UserPreferences(),
  }) => _abandonsInFlight[userQuest.id] ??= _abandonQuest(
    userQuest,
    reason,
    preferences,
  ).whenComplete(() {
    _abandonsInFlight.remove(userQuest.id);
  });

  Future<bool> _abandonQuest(
    UserQuest userQuest,
    AbandonmentReason reason,
    UserPreferences preferences,
  ) async {
    // The caller's copy can be from before the last step was completed.
    final attempt = userQuests.cast<UserQuest?>().firstWhere(
      (uq) => uq!.id == userQuest.id,
      orElse: () => userQuest,
    )!;
    if (attempt.status == 'abandoned') return true;

    final questId = attempt.questId;
    final quest = questById(questId);
    final totalSteps = stepsOf(questId).length;
    final uploadedProofs = _photoProofsAttemptId == attempt.id ? _photoProofs.length : 0;
    final hadPhotoProof =
        uploadedProofs > 0 || pendingPhotoProofs.any((proof) => proof.attemptId == attempt.id);
    final socialLevel = effectiveSocialLevel(preferences);
    try {
      final result = await _questRepository.abandonQuestOrQueue(attempt, reason: reason.code);
      abandonmentQueued = result.queued;
      _replaceUserQuest(result.userQuest);
      await _finishStepTracking(attempt.id);
      _analyticsTracker.trackDetailed(
        AnalyticsEventType.questAbandoned,
        questId: questId,
        category: quest?.category,
        availableMinutes: selectedMinutes,
        socialLevel: socialLevel,
        locationMode: selectedLocationScope,
        questDurationMinutes: quest?.durationMinutes,
        questDifficulty: quest?.difficulty,
        estimatedCost: quest?.estimatedCost,
        questLatitude: quest?.latitude,
        questLongitude: quest?.longitude,
        metadataForDistance: (distanceMeters) => questAbandonedMetadata(
          reason: reason,
          attemptId: attempt.id,
          isAnywhere: quest?.locationMode == 'anywhere',
          distanceMeters: distanceMeters,
          durationMinutes: quest?.durationMinutes,
          estimatedCost: quest?.estimatedCost,
          currentStepIndex: attempt.currentStep,
          completedSteps: attempt.completedSteps.length,
          totalSteps: totalSteps,
          hadPhotoProof: hadPhotoProof,
          uploadedPhotoProofCount: uploadedProofs,
        ),
      );
      questAlternatives = QuestAlternativesState(
        sourceQuestId: questId,
        sourceAttemptId: attempt.id,
        reason: reason,
      );
      unawaited(refreshQuestAlternatives(preferences));
      return true;
    } on AppException catch (e) {
      errorMessage = e.message;
      notifyListeners();
      return false;
    }
  }

  /// Computes the alternatives from the catalogue in memory, which is the saved
  /// one when offline. Each load logs what it showed, as in Kotlin; a load the
  /// user left behind logs nothing.
  Future<void> refreshQuestAlternatives(UserPreferences preferences) async {
    final current = questAlternatives;
    if (current == null) return;
    final generation = ++_alternativesGeneration;
    questAlternatives = QuestAlternativesState(
      sourceQuestId: current.sourceQuestId,
      sourceAttemptId: current.sourceAttemptId,
      reason: current.reason,
      suggestions: current.suggestions,
      context: current.context,
    );
    notifyListeners();

    AppContext context;
    try {
      context = await _contextWithinLimit();
    } catch (_) {
      context = _contextManager.localSnapshot(availableMinutes: selectedMinutes);
    }
    if (generation != _alternativesGeneration) return;

    final source = questById(current.sourceQuestId);
    final suggestions = source == null
        ? const <QuestAlternative>[]
        : _questAlternativeRecommender.recommend(
            catalog: catalog,
            abandonedQuest: source,
            reason: current.reason,
            context: context,
            availableMinutes: selectedMinutes,
            preferences: preferences.copyWith(
              locationMode: selectedLocationScope,
              socialLevel: sessionSocialLevel,
            ),
            excludedIds: {
              ...userQuests.map((uq) => uq.questId),
              ..._sessionSkippedQuestIds,
            },
          );
    final loaded = QuestAlternativesState(
      sourceQuestId: current.sourceQuestId,
      sourceAttemptId: current.sourceAttemptId,
      reason: current.reason,
      isLoading: false,
      suggestions: suggestions,
      context: context,
    );
    questAlternatives = loaded;
    notifyListeners();
    for (final (index, alternative) in suggestions.indexed) {
      _trackQuestAlternative(AnalyticsEventType.questAlternativeShown, loaded, alternative, index + 1);
    }
  }

  /// Only records the choice: opening its detail never accepts the mission.
  void trackQuestAlternativeSelected(QuestAlternative alternative) {
    final state = questAlternatives;
    if (state == null) return;
    final rank = state.suggestions.indexOf(alternative) + 1;
    _trackQuestAlternative(AnalyticsEventType.questAlternativeSelected, state, alternative, rank);
  }

  void _trackQuestAlternative(
    String eventType,
    QuestAlternativesState state,
    QuestAlternative alternative,
    int rank,
  ) {
    final quest = alternative.quest;
    _analyticsTracker.trackDetailed(
      eventType,
      questId: quest.id,
      category: quest.category,
      availableMinutes: selectedMinutes,
      locationMode: selectedLocationScope,
      questDurationMinutes: quest.durationMinutes,
      questDifficulty: quest.difficulty,
      estimatedCost: quest.estimatedCost,
      withCoordinates: false,
      metadataForDistance: (_) => {
        'platform': 'flutter',
        'algorithm_version': questAlternativesAlgorithmVersion,
        'source_quest_id': state.sourceQuestId,
        'source_attempt_id': state.sourceAttemptId,
        'reason_code': state.reason.code,
        'rank': rank,
        'score': alternative.score,
        'applied_rules': alternative.ruleCodes.join(','),
        'time_of_day': state.context?.timeOfDay,
        'weather_condition': state.weatherCondition ?? 'unknown',
        'context_source': 'device',
      },
    );
  }

  void dismissQuestAlternatives() {
    _alternativesGeneration++;
    questAlternatives = null;
    notifyListeners();
  }

  /// HomeShell listens: it owns the tabs, and whoever asks may be above it.
  Stream<void> get exploreTabRequests => _exploreTabRequests.stream;

  void requestExploreTab() => _exploreTabRequests.add(null);

  /// Candidates for the "shake to decide" gesture: same catalogue filter as
  /// Explore (respects `selectedMinutes`), minus quests already completed.
  /// Without a connection, only those with cached steps — their detail and
  /// mission open fully offline — unless none has them.
  List<Quest> shakeCandidates({bool isOffline = false}) {
    final completedIds = completedQuests.map((uq) => uq.questId).toSet();
    final candidates = filteredCatalog.where((quest) => !completedIds.contains(quest.id)).toList();
    if (!isOffline && !_questRepository.catalogFromCache) return candidates;
    final withSteps = candidates.where((quest) => _questRepository.hasCachedSteps(quest.id)).toList();
    return withSteps.isEmpty ? candidates : withSteps;
  }

  /// No candidates because no catalog was ever saved, as opposed to filters
  /// that exclude everything or a first load still running.
  bool shakeHasNoSavedCatalog({bool isOffline = false}) =>
      catalog.isEmpty && !isLoading && (isOffline || _questRepository.catalogFromCache);

  void trackShakeSurprise(String questId) {
    _analyticsTracker.track(
      AnalyticsEventType.shakeSurprise,
      questId: questId,
      metadata: {'quest_id': questId},
    );
  }

  // --- Feature (a): walked steps during a mission (podómetro). Counting
  // starts when a quest is accepted, survives app restarts through the
  // persisted session, and the attempt's total is saved locally when it's
  // completed or abandoned. ---

  StepCounterStatus get stepStatus => _stepCounter.status;

  /// The attempt (`user_quests.id`) being counted, null when not counting.
  String? get stepTrackedUserQuestId => _stepCounter.session?.userQuestId;

  /// Walked steps of the attempt being counted; null = no reading yet
  /// (distinct from 0 steps walked).
  int? get missionSteps {
    final session = _stepCounter.session;
    return session == null || !session.hasData ? null : session.steps;
  }

  /// "Permitir" / "Abrir ajustes" / "Contar mis pasos" on the Misión tab.
  /// Opens system settings only if the permission was already permanently
  /// denied before this tap — Android won't show its dialog again then.
  Future<void> retryStepTracking() async {
    final mission = currentMission;
    if (mission == null || !_activeMissionStatuses.contains(mission.status)) return;
    final wasPermanentlyDenied = stepStatus == StepCounterStatus.permissionPermanentlyDenied;
    final saved = _questRepository.getActiveStepSession();
    await _startStepTracking(mission, resume: saved?.userQuestId == mission.id ? saved : null);
    if (wasPermanentlyDenied && stepStatus == StepCounterStatus.permissionPermanentlyDenied) {
      await _stepCounter.openSettings();
    }
  }

  /// After an app restart: picks the persisted session back up, including
  /// the steps walked while the app was closed (the OS kept counting).
  Future<void> _resumeStepTracking() async {
    final mission = currentMission;
    if (mission == null || !_activeMissionStatuses.contains(mission.status)) return;
    final saved = _questRepository.getActiveStepSession();
    if (saved == null || saved.userQuestId != mission.id) return;
    await _startStepTracking(mission, resume: saved);
  }

  Future<void> _startStepTracking(UserQuest userQuest, {StepSession? resume}) async {
    if (_stepCounter.session?.userQuestId == userQuest.id) return;
    // Permission first: when it isn't granted (or there's no sensor),
    // nothing else is touched.
    final access = await _stepCounter.requestAccess();
    if (access != StepCounterStatus.counting) return;

    // The quest may have been completed or abandoned while the
    // permission dialog was up.
    final current = userQuests.cast<UserQuest?>().firstWhere(
      (uq) => uq!.id == userQuest.id,
      orElse: () => null,
    );
    if (current == null || !_activeMissionStatuses.contains(current.status)) return;

    // Accepting a second quest while another is counted: bank the first.
    final previous = _stepCounter.session;
    if (previous != null && previous.userQuestId != userQuest.id) {
      await _finishStepTracking(previous.userQuestId);
    }

    final session = resume ??
        StepSession(
          userQuestId: userQuest.id,
          carried: _questRepository.getStepTotals()[userQuest.id] ?? 0,
        );
    _lastPersistedSteps = null;
    _stepCounter.start(session);
    await _questRepository.saveActiveStepSession(session);
  }

  /// Saves the attempt's total and clears the active session. Also covers
  /// an attempt that was persisted but isn't being counted right now (app
  /// restarted with the permission since revoked).
  Future<void> _finishStepTracking(String userQuestId) async {
    final isCounting = _stepCounter.session?.userQuestId == userQuestId;
    final finished = isCounting ? _stepCounter.stop() : _questRepository.getActiveStepSession();
    if (finished == null || finished.userQuestId != userQuestId) return;
    _lastPersistedSteps = null;
    if (finished.hasData) {
      await _questRepository.saveStepTotal(userQuestId, finished.steps);
    }
    await _questRepository.saveActiveStepSession(null);
  }

  void _onStepCounterChange() {
    final session = _stepCounter.session;
    if (session != null && session.baseline != null) {
      final steps = session.steps;
      if (_lastPersistedSteps == null || steps - _lastPersistedSteps! >= _stepPersistInterval) {
        _lastPersistedSteps = steps;
        unawaited(_questRepository.saveActiveStepSession(session));
      }
    }
    notifyListeners();
  }

  // --- Feature (c): automatic location check-in (Strategy pattern). While
  // a mission is active and its current step needs a location, the GPS is
  // watched (stream + distanceFilter, adapted to proximity and battery by
  // LocationCheckInService); within 50 m of the quest the step completes
  // itself through completeCurrentStep — the same transition as the
  // button, so no backend change. The GPS is off in every other case. ---

  bool get isCompletingStep => _isCompletingStep;

  /// One event per automatic check-in (HomeShell shows a SnackBar).
  Stream<CheckInEvent> get checkInEvents => _checkInEvents.stream;

  StepVerificationStrategy verificationStrategyFor(QuestStep step) =>
      strategyFor(step.verificationType);

  /// Evaluated against the latest evidence (GPS fix, access, uploaded
  /// photo) of the current step.
  VerificationResult verificationResultFor(StepVerificationStrategy strategy, Quest quest) =>
      strategy.verify(quest, _currentStepEvidence());

  /// The "Completar" button: blocked while a step is being completed, and
  /// for a photo step until its proof is uploaded (location never blocks).
  bool canCompleteCurrentStep(QuestStep step, Quest quest) =>
      !_isCompletingStep &&
      strategyFor(step.verificationType).allowsManualCompletion(quest, _currentStepEvidence());

  /// HomeShell: the GPS only runs while the app is in the foreground.
  /// Coming back is also a good moment to retry pending photo uploads and a
  /// saved check-in (a failed request isn't always a connectivity change), and
  /// to re-read a last known weather: hours may have gone by, and it ages out.
  void setForeground(bool isForeground) {
    if (_isForeground == isForeground) return;
    _isForeground = isForeground;
    _syncCheckIn();
    if (isForeground) {
      unawaited(retryPendingPhotoUploads());
      unawaited(_applySavedCheckIn());
      if (currentContext?.weatherIsStale ?? false) unawaited(refreshContext());
    }
  }

  /// Location evidence from the GPS + the current step's uploaded photo.
  VerificationEvidence _currentStepEvidence() {
    final mission = currentMission;
    final stepOrder = _currentStepOrder();
    final proof = mission == null || mission.id != _photoProofsAttemptId || stepOrder == null
        ? null
        : _photoProofs[stepOrder];
    return _evidence.withPhoto(proof?.storagePath);
  }

  /// The current step's real `quest_steps.step_order`. Photo proofs are
  /// keyed by it (migration 009 checks it against quest_steps), and it is
  /// NOT the same as `user_quests.current_step` — that's a position in the
  /// ordered list, while step_order values may start at 1 or have gaps.
  int? _currentStepOrder() {
    final mission = currentMission;
    if (mission == null || _stepsQuestId != mission.questId) return null;
    if (mission.currentStep >= steps.length) return null;
    return steps[mission.currentStep].stepOrder;
  }

  /// Starts, keeps or stops the GPS watch so it only runs for an active
  /// mission's current step that needs a location and has coordinates.
  void _syncCheckIn() {
    final target = _checkInTarget();
    final key = target == null ? null : '${target.mission.id}:${target.mission.currentStep}';
    if (key == _checkInKey) return;

    _stopCheckIn();
    _checkInKey = key;
    if (key != null) unawaited(_startCheckIn(key, target!.quest));
  }

  ({UserQuest mission, Quest quest})? _checkInTarget() {
    final mission = currentMission;
    if (!_isForeground || mission == null || !_activeMissionStatuses.contains(mission.status)) {
      return null;
    }
    if (_stepsQuestId != mission.questId || isLoadingSteps) return null;
    if (mission.currentStep >= steps.length) return null;
    if (!strategyFor(steps[mission.currentStep].verificationType).needsLocation) return null;

    // No coordinates (migration 003): nothing to compare against, so the
    // GPS stays off and LocationVerification reports it as unavailable.
    final quest = questById(mission.questId);
    if (quest == null || quest.latitude == null || quest.longitude == null) return null;
    return (mission: mission, quest: quest);
  }

  Future<void> _startCheckIn(String key, Quest quest) async {
    final access = await _checkIn.start(latitude: quest.latitude!, longitude: quest.longitude!);
    if (_checkInKey != key) return; // superseded while the permission dialog was up

    _evidence = VerificationEvidence(locationAccess: access);
    if (access == LocationAccess.granted) {
      _checkInSubscription = _checkIn.fixes.listen(
        (fix) => _onCheckInFix(key, quest, fix),
        onError: (Object _) {
          // e.g. GPS switched off mid-walk; the service already stopped.
          _evidence = const VerificationEvidence(locationAccess: LocationAccess.serviceDisabled);
          notifyListeners();
        },
      );
    }
    notifyListeners();
  }

  void _onCheckInFix(String key, Quest quest, CheckInFix fix) {
    if (_checkInKey != key) return;
    _evidence = VerificationEvidence(
      locationAccess: LocationAccess.granted,
      latitude: fix.latitude,
      longitude: fix.longitude,
      accuracyMeters: fix.accuracyMeters,
    );
    notifyListeners();
    _maybeAutoCompleteByLocation();
  }

  /// Completes the current step on its own once its location is verified
  /// — and, for 'photo_and_location', its photo uploaded. Runs on every
  /// GPS fix and right after a photo upload (the user may already be
  /// standing at the place, with no new fix coming).
  void _maybeAutoCompleteByLocation() {
    final mission = currentMission;
    if (mission == null || mission.currentStep >= steps.length) return;
    if (_checkInKey != '${mission.id}:${mission.currentStep}') return; // GPS not on this step
    final quest = questById(mission.questId);
    if (quest == null) return;
    final strategy = strategyFor(steps[mission.currentStep].verificationType);
    if (!strategy.needsLocation || strategy.verify(quest, _currentStepEvidence()) is! Verified) {
      return;
    }
    // Already on the device: another GPS fix can't help until load() runs.
    if (isCheckInSavedForCurrentStep) return;

    final now = _now();
    if (_isCompletingStep ||
        (_lastAutoCheckInAt != null && now.difference(_lastAutoCheckInAt!) < _autoCheckInRetryInterval)) {
      return;
    }
    _lastAutoCheckInAt = now;
    unawaited(_autoCompleteStep(mission, quest));
  }

  Future<void> _autoCompleteStep(UserQuest mission, Quest quest) async {
    final completedQuest = await completeCurrentStep(mission);
    final updated = userQuests.cast<UserQuest?>().firstWhere(
      (uq) => uq!.id == mission.id,
      orElse: () => null,
    );
    final advanced = completedQuest || (updated != null && updated.currentStep > mission.currentStep);
    if (advanced) {
      _lastAutoCheckInAt = null;
      await _setSavedCheckIn(null);
      _checkInEvents.add(CheckInEvent(mission: mission, quest: quest, completedQuest: completedQuest));
    } else if (!_lastStepFailedForConnection) {
      // The server said no: asking again later wouldn't change that.
      await _setSavedCheckIn(null);
    } else if (_savedCheckIn == null) {
      await _setSavedCheckIn(
        VerifiedCheckIn(userQuestId: mission.id, stepIndex: mission.currentStep, verifiedAt: _now()),
      );
    }
  }

  /// The current step's location was verified and only the connection is
  /// missing: the step shows it, whether or not the user is still there.
  bool get isCheckInSavedForCurrentStep {
    final saved = _savedCheckIn;
    final mission = currentMission;
    return saved != null &&
        mission != null &&
        saved.userQuestId == mission.id &&
        saved.stepIndex == mission.currentStep;
  }

  Future<void> _setSavedCheckIn(VerifiedCheckIn? checkIn) async {
    if (checkIn == null && _savedCheckIn == null) return;
    _savedCheckIn = checkIn;
    notifyListeners();
    await _questRepository.saveVerifiedCheckIn(checkIn);
  }

  /// Completes the step of a saved check-in, or drops the check-in if that step
  /// is no longer the current one of an active mission. From load() and not
  /// only on reconnecting: an app opened with a connection never reconnects.
  /// Without a connection it fails like any other attempt and stays saved.
  Future<void> _applySavedCheckIn() async {
    final saved = _questRepository.getVerifiedCheckIn();
    _savedCheckIn = saved;
    if (saved == null) return;

    try {
      if (userQuests.isEmpty) return; // nothing known to compare it with yet
      final mission = currentMission;
      if (mission == null ||
          !_activeMissionStatuses.contains(mission.status) ||
          !isCheckInSavedForCurrentStep) {
        await _setSavedCheckIn(null);
        return;
      }

      // Without its steps, completeCurrentStep can't tell the last one apart.
      if (stepsOf(mission.questId).isEmpty) await loadSteps(mission.questId);
      final loaded = stepsOf(mission.questId);
      final quest = questById(mission.questId);
      if (mission.currentStep >= loaded.length || quest == null) return;

      final strategy = strategyFor(loaded[mission.currentStep].verificationType);
      if (strategy.needsPhoto) await _refreshPhotoProofs();
      // Being there never replaces the photo of a 'photo_and_location' step:
      // it stays saved until the photo is registered too.
      if (!isCheckInSavedForCurrentStep ||
          _isCompletingStep ||
          !strategy.allowsManualCompletion(quest, _currentStepEvidence())) {
        return;
      }
      await _autoCompleteStep(currentMission!, quest);
    } finally {
      notifyListeners();
    }
  }

  // --- Feature (f): photo proof in the private Supabase Storage bucket
  // (migration 009). The photo is kept on the device first and only
  // counts once uploaded AND registered; without connection it waits for
  // "Reintentar subida" or the automatic retries (Retry tactic). ---

  bool get isUploadingPhoto => _uploadingStoragePath != null;

  /// The current step's photo still waiting to be uploaded, if any.
  PendingPhotoProof? get currentPendingPhotoProof {
    final mission = currentMission;
    final stepOrder = _currentStepOrder();
    if (mission == null || stepOrder == null) return null;
    return pendingPhotoProofs.cast<PendingPhotoProof?>().firstWhere(
      (p) => p!.attemptId == mission.id && p.stepOrder == stepOrder,
      orElse: () => null,
    );
  }

  /// "Tomar foto" on the current step: camera → saved on the device →
  /// uploaded + registered.
  Future<void> capturePhotoProof() async {
    final mission = currentMission;
    final stepOrder = _currentStepOrder();
    if (mission == null ||
        stepOrder == null ||
        !_activeMissionStatuses.contains(mission.status) ||
        isCapturingPhoto) {
      return;
    }
    photoErrorMessage = null;
    isCapturingPhoto = true;
    notifyListeners();
    try {
      final Uint8List? jpeg;
      try {
        jpeg = await _photoCapture.capture();
      } catch (_) {
        photoErrorMessage = 'No se pudo abrir la cámara.';
        return;
      }
      if (jpeg == null) return; // backed out of the camera
      await _storeAndUploadPhoto(mission, stepOrder, jpeg, steps[mission.currentStep].verificationType);
    } on AppException catch (e) {
      photoErrorMessage = e.message;
    } catch (_) {
      // Camera worked; keeping the photo on the device didn't (e.g. the
      // web build, which has no app documents folder).
      photoErrorMessage = 'No se pudo guardar la foto en este dispositivo.';
    } finally {
      isCapturingPhoto = false;
      notifyListeners();
    }
  }

  /// "Reintentar subida".
  Future<void> retryPhotoUpload() async {
    final pending = currentPendingPhotoProof;
    if (pending != null) await _uploadPhotoProof(pending, isRetry: true);
  }

  /// Automatic retries of every pending photo: when the app loads and
  /// when it comes back to the foreground. Each is tried once per call —
  /// never a tight loop.
  Future<void> retryPendingPhotoUploads() async {
    pendingPhotoProofs = _questRepository.getPendingPhotoProofs();
    for (final pending in pendingPhotoProofs) {
      if (_uploadingStoragePath != null) return;
      await _uploadPhotoProof(pending, isRetry: true);
    }
  }

  /// Android may have killed the app while the camera was open: the photo
  /// comes back on the next launch (MissionTabView asks on open).
  Future<void> recoverLostPhotoProof() async {
    final mission = currentMission;
    if (mission == null || !_activeMissionStatuses.contains(mission.status)) return;
    final stepOrder = _currentStepOrder();
    if (stepOrder == null) return;
    if (!strategyFor(steps[mission.currentStep].verificationType).needsPhoto) return;
    try {
      final jpeg = await _photoCapture.retrieveLost();
      if (jpeg != null) {
        await _storeAndUploadPhoto(mission, stepOrder, jpeg, steps[mission.currentStep].verificationType);
      }
    } on AppException catch (e) {
      photoErrorMessage = e.message;
      notifyListeners();
    } catch (_) {
      // Nothing to recover on this platform.
    }
  }

  Future<void> _storeAndUploadPhoto(
    UserQuest mission,
    int stepOrder,
    Uint8List jpeg,
    String verificationType,
  ) async {
    if (!_questRepository.canKeepPhotosOnDevice) {
      await _uploadPhotoDirectly(mission, stepOrder, jpeg, verificationType);
      return;
    }
    final pending = await _questRepository.savePendingPhotoProof(
      attempt: mission,
      stepOrder: stepOrder,
      jpeg: jpeg,
      verificationType: verificationType,
    );
    pendingPhotoProofs = _questRepository.getPendingPhotoProofs();
    await _uploadPhotoProof(pending, isRetry: false);
  }

  Future<void> _uploadPhotoProof(PendingPhotoProof pending, {required bool isRetry}) async {
    if (_uploadingStoragePath != null) return;
    _uploadingStoragePath = pending.storagePath;
    photoErrorMessage = null;
    notifyListeners();
    try {
      final proof = await _questRepository.uploadPendingPhotoProof(pending);
      _onPhotoProofRegistered(
        proof,
        questId: pending.questId,
        byteCount: pending.sizeBytes,
        verificationType: pending.verificationType,
        wasRetry: isRetry || pending.attempts > 0,
      );
    } on AppException catch (e) {
      // Retryable: the repository kept the photo with this message as
      // its lastError ("Reintentar subida"). Not retryable: it's gone.
      if (!e.isRetryable) photoErrorMessage = e.message;
    } finally {
      _uploadingStoragePath = null;
      pendingPhotoProofs = _questRepository.getPendingPhotoProofs();
      notifyListeners();
    }
    _maybeAutoCompleteByLocation();
    await _applySavedCheckIn();
  }

  /// Web build: no device storage to keep the photo in, so it goes up
  /// straight from memory; a failure (even offline) asks for a new photo.
  Future<void> _uploadPhotoDirectly(
    UserQuest mission,
    int stepOrder,
    Uint8List jpeg,
    String verificationType,
  ) async {
    if (_uploadingStoragePath != null) return;
    _uploadingStoragePath = _directUploadMarker;
    photoErrorMessage = null;
    notifyListeners();
    try {
      final proof = await _questRepository.uploadPhotoProofDirectly(
        attempt: mission,
        stepOrder: stepOrder,
        jpeg: jpeg,
      );
      _onPhotoProofRegistered(
        proof,
        questId: mission.questId,
        byteCount: jpeg.length,
        verificationType: verificationType,
        wasRetry: false,
      );
    } on AppException catch (e) {
      photoErrorMessage = e.message;
    } finally {
      _uploadingStoragePath = null;
      notifyListeners();
    }
    _maybeAutoCompleteByLocation();
    await _applySavedCheckIn();
  }

  /// [_uploadingStoragePath] while a web upload (no pending path) runs.
  static const _directUploadMarker = '<direct-upload>';

  /// Makes the proof the step's evidence and emits photo_proof_uploaded,
  /// only after the table insert succeeded. Same name AND metadata keys as
  /// Kotlin (see EVENT_SCHEMA.md); was_retry is Flutter's optional extra.
  void _onPhotoProofRegistered(
    QuestPhotoProof proof, {
    required String questId,
    required int byteCount,
    required String? verificationType,
    required bool wasRetry,
  }) {
    if (_photoProofsAttemptId != proof.attemptId) {
      _photoProofsAttemptId = proof.attemptId;
      _photoProofs = {};
    }
    _photoProofs[proof.stepOrder] = proof;

    _analyticsTracker.track(
      AnalyticsEventType.photoProofUploaded,
      questId: questId,
      category: questById(questId)?.category,
      metadata: {
        'attempt_id': proof.attemptId,
        'step_index': proof.stepOrder, // zero-based, = quest_photo_proofs.step_order
        'storage_path': proof.storagePath,
        'byte_count': byteCount,
        'verification_type': ?verificationType,
        'was_retry': wasRetry,
      },
    );
  }

  /// This attempt's registered proofs, so evidence survives an app
  /// restart or a new device. Offline: keep what's known.
  Future<void> _refreshPhotoProofs() async {
    final mission = currentMission;
    if (mission == null || _stepsQuestId != mission.questId) return;
    final hasPhotoSteps = steps.any((step) => strategyFor(step.verificationType).needsPhoto);
    if (hasPhotoSteps) {
      pendingPhotoProofs = _questRepository.getPendingPhotoProofs();
      try {
        final proofs = await _questRepository.getPhotoProofs(mission.id);
        _photoProofsAttemptId = mission.id;
        // Newest first from the repository: the first one per step wins.
        _photoProofs = {};
        for (final proof in proofs) {
          _photoProofs.putIfAbsent(proof.stepOrder, () => proof);
        }
      } on AppException {
        // Offline.
      }
    }
    notifyListeners();
    _maybeAutoCompleteByLocation();
  }

  void _stopCheckIn() {
    _checkInSubscription?.cancel();
    _checkInSubscription = null;
    _checkIn.stop();
    _evidence = const VerificationEvidence();
  }

  @override
  void dispose() {
    _stepCounterSubscription.cancel();
    _stepCounter.dispose();
    _stopCheckIn();
    _checkIn.dispose();
    _checkInEvents.close();
    _exploreTabRequests.close();
    super.dispose();
  }

  void _replaceUserQuest(UserQuest updated) {
    userQuests = [updated, ...userQuests.where((uq) => uq.id != updated.id)];
    _syncCheckIn();
    notifyListeners();
  }

  // --- Profile stats/rewards/badges, all computed from real user_quests +
  // catalog data (no rewards/badges table exists in the backend). ---

  List<UserQuest> get completedQuests {
    final list = userQuests.where((uq) => uq.status == 'completed').toList();
    list.sort(
      (a, b) => (b.completedAt ?? b.acceptedAt).compareTo(a.completedAt ?? a.acceptedAt),
    );
    return list;
  }

  int get completedCount => completedQuests.length;

  Set<String> get completedCategories => completedQuests
      .map((uq) => questById(uq.questId)?.category)
      .whereType<String>()
      .toSet();

  /// Consecutive days (ending today or yesterday) with at least one
  /// completed quest.
  int get currentStreakDays {
    final today = DateTime.now();
    final todayDate = DateTime(today.year, today.month, today.day);
    final dates =
        completedQuests
            .map((uq) => uq.completedAt)
            .whereType<DateTime>()
            .map((dt) => DateTime(dt.year, dt.month, dt.day))
            .toSet()
            .toList()
          ..sort((a, b) => b.compareTo(a));
    if (dates.isEmpty) return 0;

    var cursor = todayDate;
    if (dates.first != todayDate) {
      if (dates.first == todayDate.subtract(const Duration(days: 1))) {
        cursor = dates.first;
      } else {
        return 0;
      }
    }
    var streak = 0;
    for (final date in dates) {
      if (date == cursor) {
        streak++;
        cursor = cursor.subtract(const Duration(days: 1));
      } else if (date.isBefore(cursor)) {
        break;
      }
    }
    return streak;
  }

  bool _completedAnyIn(String category) => completedQuests.any(
    (uq) => questById(uq.questId)?.category.toLowerCase() == category,
  );

  bool get badgeFirstMission => completedCount >= 1;
  bool get badgeExplorer => completedCategories.length >= 3;
  bool get badgeGourmet => _completedAnyIn('food');
  bool get badgeArtLover => _completedAnyIn('art');
  bool get badgeSevenDayStreak => currentStreakDays >= 7;
  bool get badgeBookworm => _completedAnyIn('learning');
}
