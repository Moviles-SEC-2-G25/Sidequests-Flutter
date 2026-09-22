import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sidequests/analytics/analytics_event_sink.dart';
import 'package:sidequests/analytics/analytics_event_type.dart';
import 'package:sidequests/analytics/analytics_tracker.dart';
import 'package:sidequests/analytics/onboarding_step.dart';
import 'package:sidequests/data/context/context_manager.dart';
import 'package:sidequests/data/services/battery_monitor.dart';
import 'package:sidequests/data/services/location_service.dart';
import 'package:sidequests/repository/auth_repository.dart';
import 'package:sidequests/viewmodel/auth/auth_view_model.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Captures whatever [AnalyticsTracker] would actually send to Supabase,
/// without touching the network.
class _RecordingEventSink implements AnalyticsEventSink {
  final List<Map<String, dynamic>> events = [];

  @override
  Future<void> insertAnalyticsEvent(Map<String, dynamic> event) async {
    events.add(event);
  }
}

// Device-sensor fakes so ContextManager.snapshot() never touches a real
// platform channel under `flutter test`.
class _NoLocation extends LocationService {
  @override
  Future<Position?> getCurrentPosition({
    LocationAccuracy accuracy = LocationAccuracy.medium,
  }) async => null;
}

class _FullBattery extends BatteryMonitor {
  @override
  Future<bool> isLow() async => false;
}

/// Stands in for AuthRepository so AuthViewModel can be constructed without
/// a real Supabase session.
class _FakeAuthRepository implements AuthRepository {
  @override
  User? get currentUser => null;

  @override
  String? get currentUserEmail => null;

  @override
  bool get isAuthenticated => false;

  @override
  Stream<AuthState> get authStateChanges => const Stream.empty();

  @override
  Future<void> signUp({required String email, required String password}) async {}

  @override
  Future<void> signIn({required String email, required String password}) async {}

  @override
  Future<void> signOut() async {}
}

/// Records the exact arguments AuthViewModel.trackOnboardingStep passes to
/// AnalyticsTracker.track, without exercising the (already covered
/// elsewhere) context-snapshot/network path.
class _SpyAnalyticsTracker extends AnalyticsTracker {
  final List<Map<String, dynamic>> calls = [];

  _SpyAnalyticsTracker()
    : super(
        eventSink: _RecordingEventSink(),
        contextManager: ContextManager(
          locationService: _NoLocation(),
          batteryMonitor: _FullBattery(),
        ),
        sessionId: 'unused',
      );

  @override
  Future<void> track(
    String eventType, {
    String? questId,
    String? category,
    int? availableMinutes,
    String? locationMode,
    int? questDurationMinutes,
    String? questDifficulty,
    double? estimatedCost,
    Map<String, dynamic> metadata = const {},
  }) async {
    calls.add({'eventType': eventType, 'metadata': metadata});
  }
}

void main() {
  test('AuthViewModel.trackOnboardingStep sends step_order/step_name matching OnboardingStep', () {
    final spyTracker = _SpyAnalyticsTracker();
    final authViewModel = AuthViewModel(_FakeAuthRepository(), spyTracker);

    authViewModel.trackOnboardingStep(OnboardingStep.welcome);
    authViewModel.trackOnboardingStep(OnboardingStep.preferences);

    expect(spyTracker.calls, [
      {
        'eventType': AnalyticsEventType.onboardingStepCompleted,
        'metadata': {'step_order': 1, 'step_name': 'welcome'},
      },
      {
        'eventType': AnalyticsEventType.onboardingStepCompleted,
        'metadata': {'step_order': 2, 'step_name': 'preferences'},
      },
    ]);
  });

  test(
    'the map passed to insertAnalyticsEvent for onboarding_step_completed has '
    'exactly step_order (int) and step_name (String) in metadata',
    () async {
      final eventSink = _RecordingEventSink();
      final tracker = AnalyticsTracker(
        eventSink: eventSink,
        contextManager: ContextManager(
          locationService: _NoLocation(),
          batteryMonitor: _FullBattery(),
        ),
        sessionId: 'test-session-id',
      );

      await tracker.track(
        AnalyticsEventType.onboardingStepCompleted,
        metadata: {
          'step_order': OnboardingStep.welcome.order,
          'step_name': OnboardingStep.welcome.stepName,
        },
      );
      await tracker.track(
        AnalyticsEventType.onboardingStepCompleted,
        metadata: {
          'step_order': OnboardingStep.preferences.order,
          'step_name': OnboardingStep.preferences.stepName,
        },
      );

      expect(eventSink.events, hasLength(2));
      final welcomeEvent = eventSink.events[0];
      final preferencesEvent = eventSink.events[1];

      expect(welcomeEvent['event_type'], 'onboarding_step_completed');
      expect(welcomeEvent['session_id'], 'test-session-id');
      // No GPS -> latitude/longitude keys must be absent, not null.
      expect(welcomeEvent.containsKey('latitude'), isFalse);
      expect(welcomeEvent.containsKey('longitude'), isFalse);

      final welcomeMetadata = welcomeEvent['metadata'] as Map<String, dynamic>;
      expect(welcomeMetadata.keys.toSet(), {'step_order', 'step_name'});
      expect(welcomeMetadata['step_order'], isA<int>());
      expect(welcomeMetadata['step_order'], 1);
      expect(welcomeMetadata['step_name'], isA<String>());
      expect(welcomeMetadata['step_name'], 'welcome');

      final preferencesMetadata = preferencesEvent['metadata'] as Map<String, dynamic>;
      expect(preferencesMetadata, {'step_order': 2, 'step_name': 'preferences'});

      // Same onboarding attempt -> same session_id across steps.
      expect(preferencesEvent['session_id'], welcomeEvent['session_id']);

      // `user_id` is stamped by SupabaseRemoteDataSource at insert time, not
      // by AnalyticsTracker, so it must not appear on the map at this seam.
      expect(welcomeEvent.containsKey('user_id'), isFalse);
    },
  );
}
