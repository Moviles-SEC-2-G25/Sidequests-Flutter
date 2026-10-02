import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../analytics/analytics_event_type.dart';
import '../../analytics/analytics_tracker.dart';
import '../../core/app_exception.dart';
import '../../core/completion_likelihood.dart';
import '../../core/similar_quest_recommender.dart';
import '../../core/verification/step_verification_strategy.dart';
import '../../core/verification/verification_strategies.dart';
import '../../data/context/context_manager.dart';
import '../../data/services/location_check_in_service.dart';
import '../../data/services/photo_capture_service.dart';
import '../../data/services/step_counter_service.dart';
import '../../models/app_context.dart';
import '../../models/photo_proof.dart';
import '../../models/quest.dart';
import '../../models/quest_recommendation.dart';
import '../../models/quest_step.dart';
import '../../models/step_session.dart';
import '../../models/user_preferences.dart';
import '../../models/user_quest.dart';
import '../../repository/quest_repository.dart';

const List<int> kAvailableMinuteOptions = [10, 20, 30, 45, 60];

/// Statuses that mean "not finished yet" — a quest in one of these can still
/// be resumed from the Explore "continue" banner or the Misión tab.
const _unfinishedStatuses = {'accepted', 'in_progress', 'abandoned'};

/// A mission being actively done: walked steps are counted and the GPS
/// check-in runs (an abandoned quest pauses both until it's resumed).
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

  /// `"<user_quests.id>:<currentStep>"` of the step whose location is being
  /// watched; null when the GPS is off.
  String? _checkInKey;
  VerificationEvidence _evidence = const VerificationEvidence();
  bool _isForeground = true;
  bool _isCompletingStep = false;
  DateTime? _lastAutoCheckInAt;

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
  List<UserQuest> userQuests = [];
  List<QuestStep> steps = [];
  String? _stepsQuestId;
  bool isLoading = false;
  bool isLoadingRecommendations = false;
  bool isLoadingSteps = false;
  String? errorMessage;
  bool isSubmittingRating = false;
  String? ratingErrorMessage;

  int selectedMinutes = 30;
  String selectedLocationScope = 'all'; // all | gps | anywhere
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

  QuestViewModel(
    this._questRepository,
    this._contextManager,
    this._analyticsTracker,
    this._userId, {
    SimilarQuestRecommender similarQuestRecommender = const SimilarQuestRecommender(),
    CompletionLikelihood completionLikelihood = const CompletionLikelihood(),
    StepCounterService? stepCounter,
    LocationCheckInService? locationCheckIn,
    PhotoCaptureService? photoCapture,
  }) : _similarQuestRecommender = similarQuestRecommender,
       _completionLikelihood = completionLikelihood,
       _stepCounter = stepCounter ?? StepCounterService(),
       _checkIn = locationCheckIn ?? LocationCheckInService(),
       _photoCapture = photoCapture ?? PhotoCaptureService() {
    _stepCounterSubscription = _stepCounter.onChange.listen((_) => _onStepCounterChange());
  }

  /// The quest to resume from "Continúa donde lo dejaste" / the Misión tab:
  /// the most recently touched quest that isn't completed. `userQuests` is
  /// already ordered by `updated_at desc` by the repository query.
  UserQuest? get currentMission => userQuests
      .cast<UserQuest?>()
      .firstWhere((uq) => _unfinishedStatuses.contains(uq!.status), orElse: () => null);

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
      catalog = await _questRepository.getCatalog();
      userQuests = await _questRepository.getUserQuests(_userId);
      unawaited(_resumeStepTracking());
      unawaited(retryPendingPhotoUploads());
    } on AppException catch (e) {
      errorMessage = e.message;
    } finally {
      isLoading = false;
      _syncCheckIn();
      notifyListeners();
    }
  }

  void setMinutes(int minutes) {
    selectedMinutes = minutes;
    registerInteraction();
    notifyListeners();
  }

  void setCategory(String? category) {
    selectedCategory = category;
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

  /// BQ10 (location-independent mode usage) is measured from this event.
  void setLocationScope(String scope) {
    selectedLocationScope = scope;
    registerInteraction();
    notifyListeners();
    _analyticsTracker.track(
      AnalyticsEventType.locationModeSelected,
      locationMode: scope,
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
      final context = await _contextManager.snapshot(availableMinutes: selectedMinutes);
      currentContext = context;
      final effectivePreferences = preferences.copyWith(
        locationMode: selectedLocationScope,
        socialLevel: sessionSocialLevel,
      );
      recommendations = await _questRepository.getRecommendations(
        context: context,
        preferences: effectivePreferences,
        excludedQuestIds: _sessionSkippedQuestIds.toList(),
      );
      // One batch_id per RPC call so BQ8 can group the events of one list.
      final batchId = const Uuid().v4();
      // BQ4: starts the decision clock on the first non-empty list shown
      // since the app opened (or since the last quest was started) — later
      // reloads (filter changes, "Ahora no") don't restart it.
      if (recommendations.isNotEmpty) {
        _decisionStartedAt ??= DateTime.now();
        _decisionBatchId ??= batchId;
      }
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

  /// [wasRecommended] also picks BQ4's start_path: 'standard' from a
  /// recommendation's detail view, 'catalog' from "Todas las misiones".
  Future<void> acceptQuest(String questId, {bool wasRecommended = false}) async {
    await _acceptQuest(
      questId,
      startPath: wasRecommended ? 'standard' : 'catalog',
      wasRecommended: wasRecommended,
    );
  }

  /// "Empezar ya" on a recommendation card (BQ4's 'instant_plan' start
  /// path): accepts the quest and preloads its steps, skipping
  /// QuestDetailView entirely. The caller navigates to MissionTabView once
  /// this returns true.
  Future<bool> startInstantPlan(Quest quest) async {
    final started = await _acceptQuest(quest.id, startPath: 'instant_plan', wasRecommended: true);
    if (!started) return false;
    await loadSteps(quest.id);
    return true;
  }

  Future<bool> _acceptQuest(
    String questId, {
    required String startPath,
    required bool wasRecommended,
  }) async {
    try {
      final userQuest = await _questRepository.acceptQuest(
        userId: _userId,
        questId: questId,
      );
      _replaceUserQuest(userQuest);
      // Not awaited: the permission dialog shows over the Misión screen
      // instead of holding up the navigation to it.
      unawaited(_startStepTracking(userQuest));
      final quest = questById(questId);
      // BQ4: how much a ready-to-execute plan (vs. browsing the detail page)
      // shortens the trip from seeing recommendations to starting a quest.
      final secondsToStart = _decisionStartedAt == null
          ? 0
          : DateTime.now().difference(_decisionStartedAt!).inSeconds;
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
          'batch_id': _decisionBatchId,
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

  /// A new decision journey starts the next time recommendations are shown.
  void _resetDecisionJourney() {
    _decisionStartedAt = null;
    _decisionBatchId = null;
    _interactionCount = 0;
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

  Future<void> loadSteps(String questId) async {
    isLoadingSteps = true;
    _stepsQuestId = questId;
    notifyListeners();
    try {
      steps = await _questRepository.getSteps(questId);
    } on AppException catch (e) {
      errorMessage = e.message;
    } finally {
      isLoadingSteps = false;
      _syncCheckIn();
      notifyListeners();
      unawaited(_refreshPhotoProofs());
    }
  }

  /// Advances the current step (or completes the quest on the last one).
  /// Transitions 'accepted' -> 'in_progress' on the first step so the
  /// backend's lifecycle trigger stamps `started_at` for real.
  /// Returns true only when this call completed the whole quest.
  ///
  /// Shared by the "Completar" button and the automatic location check-in;
  /// [isCompletingStep] keeps the two from advancing the same step twice.
  Future<bool> completeCurrentStep(UserQuest userQuest) async {
    if (_isCompletingStep) return false;
    _isCompletingStep = true;
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
      } else if (userQuest.status == 'abandoned') {
        // Resuming an abandoned attempt keeps adding to its saved total.
        unawaited(_startStepTracking(updated));
      }
      return isLastStep;
    } on AppException catch (e) {
      errorMessage = e.message;
      return false;
    } finally {
      _isCompletingStep = false;
      notifyListeners();
    }
  }

  /// Saves the post-mission rating/feedback and emits 'quest_rated'.
  /// Returns true on success; on failure `ratingErrorMessage` is set.
  Future<bool> submitRating(
    UserQuest userQuest, {
    required int rating,
    required List<String> tags,
  }) async {
    isSubmittingRating = true;
    ratingErrorMessage = null;
    notifyListeners();
    try {
      final updated = await _questRepository.rateQuest(userQuest, rating, tags);
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

  Future<void> abandonQuest(UserQuest userQuest, {required String reason}) async {
    try {
      final updated = await _questRepository.abandonQuest(userQuest, reason: reason);
      _replaceUserQuest(updated);
      await _finishStepTracking(updated.id);
      final quest = questById(updated.questId);
      _analyticsTracker.track(
        AnalyticsEventType.questAbandoned,
        questId: updated.questId,
        category: quest?.category,
        questDurationMinutes: quest?.durationMinutes,
        questDifficulty: quest?.difficulty,
        estimatedCost: quest?.estimatedCost,
        questLatitude: quest?.latitude,
        questLongitude: quest?.longitude,
        metadata: {
          'reason': reason,
          'step': userQuest.currentStep,
          'completed_steps': userQuest.completedSteps.length,
        },
      );
    } on AppException catch (e) {
      errorMessage = e.message;
      notifyListeners();
    }
  }

  /// Candidates for the "shake to decide" gesture: same catalogue filter as
  /// Explore (respects `selectedMinutes`), minus quests already completed.
  List<Quest> get shakeCandidates {
    final completedIds = completedQuests.map((uq) => uq.questId).toSet();
    return filteredCatalog.where((quest) => !completedIds.contains(quest.id)).toList();
  }

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
  /// Coming back is also a good moment to retry pending photo uploads.
  void setForeground(bool isForeground) {
    if (_isForeground == isForeground) return;
    _isForeground = isForeground;
    _syncCheckIn();
    if (isForeground) unawaited(retryPendingPhotoUploads());
  }

  /// Location evidence from the GPS + the current step's uploaded photo.
  VerificationEvidence _currentStepEvidence() {
    final mission = currentMission;
    final proof = mission == null || mission.id != _photoProofsAttemptId
        ? null
        : _photoProofs[mission.currentStep];
    return _evidence.withPhoto(proof?.storagePath);
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

    final now = DateTime.now();
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
      _checkInEvents.add(CheckInEvent(mission: mission, quest: quest, completedQuest: completedQuest));
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
    if (mission == null) return null;
    return pendingPhotoProofs.cast<PendingPhotoProof?>().firstWhere(
      (p) => p!.attemptId == mission.id && p.stepOrder == mission.currentStep,
      orElse: () => null,
    );
  }

  /// "Tomar foto" on the current step: camera → saved on the device →
  /// uploaded + registered.
  Future<void> capturePhotoProof() async {
    final mission = currentMission;
    if (mission == null || !_activeMissionStatuses.contains(mission.status) || isCapturingPhoto) {
      return;
    }
    final stepOrder = mission.currentStep;
    photoErrorMessage = null;
    isCapturingPhoto = true;
    notifyListeners();
    try {
      final jpeg = await _photoCapture.capture();
      if (jpeg == null) return; // backed out of the camera
      await _storeAndUploadPhoto(mission, stepOrder, jpeg);
    } on AppException catch (e) {
      photoErrorMessage = e.message;
    } catch (_) {
      photoErrorMessage = 'No se pudo abrir la cámara.';
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
    if (_stepsQuestId != mission.questId || mission.currentStep >= steps.length) return;
    if (!strategyFor(steps[mission.currentStep].verificationType).needsPhoto) return;
    try {
      final jpeg = await _photoCapture.retrieveLost();
      if (jpeg != null) await _storeAndUploadPhoto(mission, mission.currentStep, jpeg);
    } on AppException catch (e) {
      photoErrorMessage = e.message;
      notifyListeners();
    } catch (_) {
      // Nothing to recover on this platform.
    }
  }

  Future<void> _storeAndUploadPhoto(UserQuest mission, int stepOrder, Uint8List jpeg) async {
    final pending = await _questRepository.savePendingPhotoProof(
      attempt: mission,
      stepOrder: stepOrder,
      jpeg: jpeg,
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
      if (_photoProofsAttemptId != proof.attemptId) {
        _photoProofsAttemptId = proof.attemptId;
        _photoProofs = {};
      }
      _photoProofs[proof.stepOrder] = proof;

      final quest = questById(pending.questId);
      // Same name Kotlin emits; only after the table insert succeeded.
      _analyticsTracker.track(
        AnalyticsEventType.photoProofUploaded,
        questId: pending.questId,
        category: quest?.category,
        metadata: {
          'attempt_id': proof.attemptId,
          'step_order': proof.stepOrder,
          'was_retry': isRetry || pending.attempts > 0,
          'size_bytes': pending.sizeBytes,
        },
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
