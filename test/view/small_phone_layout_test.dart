import 'dart:async';
import 'dart:io';

import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import 'package:sidequests/analytics/analytics_event_sink.dart';
import 'package:sidequests/analytics/analytics_tracker.dart';
import 'package:sidequests/core/app_exception.dart';
import 'package:sidequests/core/mission_history.dart';
import 'package:sidequests/core/quest_alternative_recommender.dart';
import 'package:sidequests/core/verification/step_verification_strategy.dart';
import 'package:sidequests/core/workers/similar_quest_worker.dart';
import 'package:sidequests/data/context/context_manager.dart';
import 'package:sidequests/data/local/local_data_source.dart';
import 'package:sidequests/data/services/battery_monitor.dart';
import 'package:sidequests/data/services/biometric_service.dart';
import 'package:sidequests/data/services/location_check_in_service.dart';
import 'package:sidequests/data/services/location_service.dart';
import 'package:sidequests/data/services/photo_capture_service.dart';
import 'package:sidequests/data/services/shake_detector.dart';
import 'package:sidequests/data/services/step_counter_service.dart';
import 'package:sidequests/data/services/weather_service.dart';
import 'package:sidequests/models/abandonment_reason.dart';
import 'package:sidequests/models/app_context.dart';
import 'package:sidequests/models/explore_filters.dart';
import 'package:sidequests/models/photo_proof.dart';
import 'package:sidequests/models/profile.dart';
import 'package:sidequests/models/quest.dart';
import 'package:sidequests/models/quest_recommendation.dart';
import 'package:sidequests/models/quest_step.dart';
import 'package:sidequests/models/step_log_entry.dart';
import 'package:sidequests/models/step_session.dart';
import 'package:sidequests/models/user_preferences.dart';
import 'package:sidequests/models/user_quest.dart';
import 'package:sidequests/models/verified_check_in.dart';
import 'package:sidequests/repository/auth_repository.dart';
import 'package:sidequests/repository/quest_repository.dart';
import 'package:sidequests/view/auth/biometric_lock_view.dart';
import 'package:sidequests/view/auth/login_view.dart';
import 'package:sidequests/view/auth/onboarding_view.dart';
import 'package:sidequests/view/auth/otp_login_view.dart';
import 'package:sidequests/view/auth/signup_view.dart';
import 'package:sidequests/view/home_shell.dart';
import 'package:sidequests/view/profile/change_password_dialog.dart';
import 'package:sidequests/view/profile/edit_preferences_view.dart';
import 'package:sidequests/view/profile/mission_history_view.dart';
import 'package:sidequests/view/profile/profile_view.dart';
import 'package:sidequests/view/profile/stats_view.dart';
import 'package:sidequests/view/quests/abandon_mission_view.dart';
import 'package:sidequests/view/quests/explore_view.dart';
import 'package:sidequests/view/quests/mission_tab_view.dart';
import 'package:sidequests/view/quests/nearby_view.dart';
import 'package:sidequests/view/quests/quest_alternatives_view.dart';
import 'package:sidequests/view/quests/quest_completed_view.dart';
import 'package:sidequests/view/quests/quest_detail_view.dart';
import 'package:sidequests/view/social/social_view.dart';
import 'package:sidequests/view/widgets/context_banner.dart';
import 'package:sidequests/view/widgets/sponsored_badge.dart';
import 'package:sidequests/viewmodel/auth/auth_view_model.dart';
import 'package:sidequests/viewmodel/context/connectivity_view_model.dart';
import 'package:sidequests/viewmodel/context/context_status_view_model.dart';
import 'package:sidequests/viewmodel/profile/mission_history_view_model.dart';
import 'package:sidequests/viewmodel/profile/profile_view_model.dart';
import 'package:sidequests/viewmodel/profile/stats_view_model.dart';
import 'package:sidequests/viewmodel/quests/quest_view_model.dart';
import 'package:sidequests/viewmodel/theme_view_model.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthState;

/// Every screen on small phones (320 and 360 dp wide), with the system text
/// at 100 % and 130 %, online and offline, filled with long real-world text.
/// Any overflow fails: in a debug build it is the yellow-and-black stripes
/// with "OVERFLOWED BY … PIXELS", and in release the content is cut off.
///
/// Uses the real Roboto from the Flutter SDK: the default test font draws
/// every glyph as a square, about twice as wide as real text, which would
/// flag layouts that fit fine on a phone.

const _long = 'Recorrido fotográfico por los murales escondidos del centro histórico';

Quest _quest(String id, {String social = 'solo', String mode = 'anywhere'}) => Quest(
  id: id,
  title: '$_long $id',
  description: 'Descripción larga de la misión $id para probar el diseño en un teléfono pequeño. ' * 2,
  category: 'art',
  durationMinutes: 45,
  estimatedCost: 25000,
  difficulty: 'medium',
  locationMode: mode,
  socialLevel: social,
  locationName: 'Museo de Arte Moderno de Bogotá, Calle 24 #6-00',
  isNew: true,
  // Every badge on at once: sponsored quests are always labelled (BQ12).
  isSponsored: true,
  sponsorName: 'Fundación Museo de Arte Moderno de Bogotá y Amigos del Centro Histórico',
  sponsorBusinessCategory: 'arts_and_culture',
);

final _catalog = [
  _quest('a'),
  _quest('b', social: 'group', mode: 'gps'),
  _quest('c', social: 'social', mode: 'gps'),
];

final _attempts = [
  UserQuest(id: 'uq-a', userId: 'u', questId: 'a', status: 'in_progress', acceptedAt: DateTime(2026, 11, 1)),
  // Enough completed missions to earn badges and milestones ("EARNED").
  for (var i = 0; i < 6; i++)
    UserQuest(
      id: 'done-$i',
      userId: 'u',
      questId: 'b',
      status: 'completed',
      acceptedAt: DateTime.now().subtract(Duration(days: i)),
      completedAt: DateTime.now().subtract(Duration(days: i)),
    ),
];

const _evening = AppContext(timeOfDay: 'evening', dayOfWeek: 'friday', isConnected: false);

/// Screens whose first view shows one of the (sponsored) quests above.
/// ('alternativas' gets no suggestion from this catalogue: its empty state.)
const _showsSponsoredQuest = {'Explore', 'Quest', 'detalle (solo)', 'detalle (grupo)'};

class _Connectivity implements Connectivity {
  final bool offline;

  _Connectivity({required this.offline});

  @override
  Future<List<ConnectivityResult>> checkConnectivity() async =>
      [offline ? ConnectivityResult.none : ConnectivityResult.wifi];

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Low, so the shell's banner shows when online too.
class _LowBattery implements Battery {
  @override
  Future<int> get batteryLevel async => 10;

  @override
  Stream<BatteryState> get onBatteryStateChanged => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoLocation extends LocationService {
  @override
  Future<Position?> getCurrentPosition({LocationAccuracy accuracy = LocationAccuracy.medium}) async =>
      null;
}

class _FullBattery extends BatteryMonitor {
  @override
  Future<bool> isLow() async => false;
}

class _NoLostPhoto extends PhotoCaptureService {
  @override
  Future<Uint8List?> retrieveLost() async => null;
}

class _NullSink implements AnalyticsEventSink {
  @override
  Future<void> insertAnalyticsEvent(Map<String, dynamic> event) async {}
}

ContextManager _contextManager() => ContextManager(
  locationService: _NoLocation(),
  batteryMonitor: _FullBattery(),
  connectivity: _Connectivity(offline: false),
);

class _SilentTracker extends AnalyticsTracker {
  _SilentTracker() : super(eventSink: _NullSink(), contextManager: _contextManager(), sessionId: 'x');

  @override
  Future<void> trackDetailed(
    String eventType, {
    String? questId,
    String? category,
    int? availableMinutes,
    String? socialLevel,
    String? locationMode,
    int? questDurationMinutes,
    String? questDifficulty,
    double? estimatedCost,
    double? questLatitude,
    double? questLongitude,
    required Map<String, dynamic> Function(int? distanceMeters) metadataForDistance,
    bool withCoordinates = true,
  }) async {}
}

/// Everything the screens read, from the device's saved copy.
class _SavedQuests implements QuestRepository {
  /// Long names and big numbers, so "Your walks" is checked too.
  @override
  Future<WalkStats> getWalkStats({required DateTime since}) async => (
    recentSteps: 1234567,
    stepsByCategory: [(category: _catalog.first.category, steps: 1234567)],
    longestWalk: StepLogEntry(
      attemptId: 'w',
      questId: _catalog.first.id,
      category: _catalog.first.category,
      steps: 1234567,
      outcome: StepLogEntry.completed,
      finishedAt: DateTime.utc(2026, 11, 26),
    ),
  );

  @override
  bool catalogFromCache = true;

  @override
  bool userQuestsFromCache = true;

  @override
  Future<List<Quest>> getCatalog() async => _catalog;

  @override
  Future<List<UserQuest>> getUserQuests(String userId) async => _attempts;

  @override
  Future<({List<UserQuest> userQuests, bool fromCache})> getUserQuestsWithSource(
    String userId,
  ) async => (userQuests: _attempts, fromCache: true);

  @override
  Future<List<QuestStep>> getSteps(String questId) async => [
    QuestStep(
      id: 0,
      questId: questId,
      stepOrder: 0,
      title: '$_long paso uno',
      description: _long,
      verificationType: 'photo_and_location',
    ),
    QuestStep(id: 1, questId: questId, stepOrder: 1, title: '$_long paso dos', verificationType: 'photo'),
    QuestStep(id: 2, questId: questId, stepOrder: 2, title: 'Paso tres'),
  ];

  @override
  Future<RecommendationBatch> getRecommendations({
    required AppContext context,
    required UserPreferences preferences,
    List<String> excludedQuestIds = const [],
    int limit = 3,
  }) async => RecommendationBatch(
    recommendations: [
      for (final quest in _catalog)
        QuestRecommendation(
          questId: quest.id,
          score: 1,
          timeMatch: true,
          interestMatch: true,
          socialMatch: true,
          locationMatch: true,
        ),
    ],
    batchId: 'saved',
    fromCache: true,
  );

  @override
  RecommendationBatch? savedRecommendations(List<String> excludedQuestIds) => null;

  @override
  Future<void> saveExploreFilters(ExploreFilters filters) async {}

  @override
  StepSession? getActiveStepSession() => null;

  @override
  VerifiedCheckIn? getVerifiedCheckIn() => null;

  /// A photo waiting for the connection, with the longest message there is.
  @override
  List<PendingPhotoProof> getPendingPhotoProofs() => [
    PendingPhotoProof(
      localPath: 'p.jpg',
      storagePath: 'u/uq-a/a/0/p.jpg',
      attemptId: 'uq-a',
      questId: 'a',
      stepOrder: 0,
      sizeBytes: 1,
      capturedAt: DateTime(2026),
      lastError: 'Offline: your photo was saved on the phone. Try again when you have internet.',
    ),
  ];

  @override
  Future<QuestPhotoProof> uploadPendingPhotoProof(PendingPhotoProof proof) async =>
      throw const AppException('Offline', isRetryable: true);

  @override
  Future<List<QuestPhotoProof>> getPhotoProofs(String attemptId) async => const [];

  @override
  bool hasCachedSteps(String questId) => true;

  @override
  Map<String, int> getStepTotals() => const {};

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The bitácora's longest lines: a rated mission, the longest abandonment
/// reason, a quest gone from the catalogue and step counts in the hundreds
/// of thousands.
class _SavedHistory extends _SavedQuests {
  @override
  Future<({List<UserQuest> userQuests, bool fromCache})> getUserQuestsWithSource(
    String userId,
  ) async => (
    userQuests: [
      ..._attempts,
      UserQuest(
        id: 'rated',
        userId: 'u',
        questId: 'c',
        status: 'completed',
        rating: 3,
        acceptedAt: DateTime(2026, 9, 1),
        completedAt: DateTime(2026, 9, 2),
      ),
      UserQuest(
        id: 'gave-up',
        userId: 'u',
        questId: 'a',
        status: 'abandoned',
        abandonReason: AbandonmentReason.placeUnavailable.code,
        acceptedAt: DateTime(2026, 9, 3),
        abandonedAt: DateTime(2026, 9, 4),
      ),
      UserQuest(
        id: 'gone',
        userId: 'u',
        questId: '$_long-sin-catalogo',
        status: 'completed',
        acceptedAt: DateTime(2026, 8, 1),
      ),
    ],
    fromCache: true,
  );

  @override
  Map<String, int> getStepTotals() => const {'rated': 123456, 'gave-up': 98765};

  /// Abandoned and rated offline: the "Pending sync" marks and
  /// the banner's count line.
  @override
  Set<String> pendingSyncAttemptIds() => const {'rated', 'gave-up'};

  /// The banner's "Última actualización" line, with its longest date.
  @override
  DateTime? userQuestsSyncedAt() => DateTime(2026, 9, 30, 23, 59);
}

/// The bitácora with the device offline or not, as the banner changes with it.
Widget _bitacora({required bool deviceOffline}) => ChangeNotifierProvider(
  create: (_) => MissionHistoryViewModel(
    _SavedHistory(),
    'u',
    runner: (input) async => buildMissionHistory(input),
    isOffline: () async => deviceOffline,
    offlineChanges: () => const Stream.empty(),
  ),
  child: const MissionHistoryView(),
);

class _Profile extends ChangeNotifier implements ProfileViewModel {
  @override
  Profile? profile = Profile(id: 'u', displayName: 'Maximiliano Alejandro', createdAt: DateTime(2026, 9));

  @override
  UserPreferences preferences = const UserPreferences(
    interests: ['art', 'food', 'nature', 'learning', 'sports'],
  );

  @override
  bool isLoading = false;

  @override
  String? errorMessage;

  @override
  String? get email => 'maximiliano.alejandro.rodriguez@uniandes.edu.co';

  @override
  Future<void> load() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Local implements LocalDataSource {
  @override
  bool isDarkMode() => false;

  @override
  bool missionNotificationsEnabled() => true;

  @override
  bool dailyRemindersEnabled() => true;

  @override
  bool hasCompletedOnboarding() => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SignedIn implements AuthRepository {
  @override
  bool get isAuthenticated => true;

  @override
  bool get isBiometricEnabled => false;

  @override
  Stream<AuthState> get authStateChanges => const Stream.empty();

  @override
  String? get currentUserEmail => 'maximiliano.alejandro.rodriguez@uniandes.edu.co';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The change-password dialog, opened over an empty screen.
class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog();

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => showChangePasswordDialog(context));
  }

  @override
  Widget build(BuildContext context) => const Scaffold();
}

/// The SDK's Roboto and Material icons, or null when they aren't there.
Future<String?> _loadRealFonts() async {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) return 'FLUTTER_ROOT is not set';
  final dir = '$root/bin/cache/artifacts/material_fonts';
  final files = ['roboto-regular.ttf', 'roboto-medium.ttf', 'roboto-bold.ttf'];
  if (!files.every((name) => File('$dir/$name').existsSync())) return 'no Roboto in $dir';

  ByteData bytes(String name) => ByteData.view(File('$dir/$name').readAsBytesSync().buffer);
  final roboto = FontLoader('Roboto');
  for (final name in files) {
    roboto.addFont(Future.value(bytes(name)));
  }
  await roboto.load();
  if (File('$dir/materialicons-regular.otf').existsSync()) {
    await (FontLoader('MaterialIcons')..addFont(Future.value(bytes('materialicons-regular.otf'))))
        .load();
  }
  return null;
}

void main() {
  String? skipReason;
  setUpAll(() async => skipReason = await _loadRealFonts());

  final screens = <String, Widget Function()>{
    'Explore': () => const ExploreView(),
    'Nearby': () => const NearbyView(),
    'Social': () => const SocialView(),
    'Quest': () => const MissionTabView(),
    'detalle (solo)': () => QuestDetailView(quest: _catalog[0]),
    'detalle (grupo)': () => QuestDetailView(quest: _catalog[1]),
    'Profile': () => const ProfileView(),
    'misión completada': () => QuestCompletedView(mission: _attempts.first, quest: _catalog[0]),
    'abandonar misión': () => AbandonMissionView(mission: _attempts.first, totalSteps: 3),
    'alternativas': () => const QuestAlternativesView(),
    'login': () => const LoginView(),
    'registro': () => const SignUpView(),
    'código por correo': () => const OtpLoginView(),
    'onboarding': () => OnboardingView(onFinished: () {}),
    'bloqueo con huella': () => const BiometricLockView(),
    'preferencias': () => const EditPreferencesView(),
    'My stats': () => ChangeNotifierProvider(
      create: (_) => StatsViewModel(_SavedQuests(), 'u', runner: (input) async => summarizeStats(input)),
      child: const StatsView(),
    ),
    // Saved copy either way: "no pudimos conectar" (online) / "sin conexión".
    'My quest log': () => _bitacora(deviceOffline: false),
    'Mi bitácora (sin red)': () => _bitacora(deviceOffline: true),
    'cambiar contraseña': () => const _PasswordDialog(),
    'banner de contexto': () => const Scaffold(body: ContextBanner()),
    'menú inferior': () =>
        HomeShell(shakeDetector: ShakeDetector(accelerometerEvents: const Stream.empty())),
  };

  for (final size in const [Size(360, 690), Size(320, 568)]) {
    for (final textScale in const [1.0, 1.3]) {
      for (final offline in const [false, true]) {
        final setting =
            '${size.width.toInt()} dp, texto ${(textScale * 100).toInt()} %, '
            '${offline ? 'sin conexión' : 'con conexión'}';
        group(setting, () {
          for (final MapEntry(key: name, value: screen) in screens.entries) {
            testWidgets('$name: nada se desborda', (tester) async {
              if (skipReason != null) {
                markTestSkipped(skipReason!);
                return;
              }
              tester.view.physicalSize = size;
              tester.view.devicePixelRatio = 1;
              tester.platformDispatcher.textScaleFactorTestValue = textScale;
              addTearDown(tester.view.reset);
              addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

              final quests = QuestViewModel(
                _SavedQuests(),
                _contextManager(),
                _SilentTracker(),
                'u',
                // "You might also like" ranked here: no isolate in testWidgets.
                similarQuestRunner: const SynchronousSimilarQuestRunner(),
                stepCounter: StepCounterService(
                  requestAccess: () async => StepCounterStatus.permissionDenied,
                ),
                locationCheckIn: LocationCheckInService(
                  requestAccess: () async => LocationAccess.denied,
                  isLowBattery: () async => false,
                  isOffline: () async => false,
                  offlineChanges: () => const Stream.empty(),
                  positions: (_, _) => const Stream.empty(),
                ),
                photoCapture: _NoLostPhoto(),
              );
              await tester.runAsync(quests.load);
              await tester.runAsync(() => quests.loadSteps('a'));
              await tester.runAsync(() => quests.loadRecommendations(const UserPreferences()));
              quests.questAlternatives = QuestAlternativesState(
                sourceQuestId: 'a',
                sourceAttemptId: 'uq-a',
                reason: AbandonmentReason.placeUnavailable,
                isLoading: false,
                context: _evening,
                suggestions: computeQuestAlternatives(
                  QuestAlternativesInput(
                    catalog: [..._catalog, _quest('d'), _quest('e')],
                    abandonedQuest: _catalog[0],
                    reason: AbandonmentReason.placeUnavailable,
                    context: _evening,
                    availableMinutes: 60,
                    preferences: const UserPreferences(),
                  ),
                ),
              );

              await tester.pumpWidget(
                MultiProvider(
                  providers: [
                    ChangeNotifierProvider<QuestViewModel>.value(value: quests),
                    ChangeNotifierProvider<ProfileViewModel>(create: (_) => _Profile()),
                    ChangeNotifierProvider(create: (_) => ThemeViewModel(_Local())),
                    ChangeNotifierProvider(
                      create: (_) => AuthViewModel(
                        _SignedIn(),
                        BiometricService(),
                        _SilentTracker(),
                        isOffline: () async => offline,
                        offlineChanges: () => const Stream.empty(),
                      ),
                    ),
                    ChangeNotifierProvider(
                      create: (_) => ConnectivityViewModel(connectivity: _Connectivity(offline: offline)),
                    ),
                    ChangeNotifierProvider(
                      create: (_) => ContextStatusViewModel(
                        connectivity: _Connectivity(offline: offline),
                        battery: _LowBattery(),
                      ),
                    ),
                    Provider<LocalDataSource>.value(value: _Local()),
                    Provider<AnalyticsTracker>.value(value: _SilentTracker()),
                    Provider<QuestRepository>.value(value: _SavedQuests()),
                    Provider<LocationService>.value(value: _NoLocation()),
                    Provider<WeatherService>.value(value: WeatherService()),
                  ],
                  child: MaterialApp(home: screen()),
                ),
              );
              await tester.pump(); // connectivity read, post-frame loads
              await tester.pump();
              if (name == 'onboarding') {
                await tester.tap(find.text('Get started')); // to the preferences step
                await tester.pump();
              }
              if (_showsSponsoredQuest.contains(name)) {
                expect(find.byType(SponsoredBadge), findsWidgets, reason: 'sin marca de patrocinio');
              }
              // Scroll to the end, so lazily built children are laid out too.
              final scrollables = find.byType(Scrollable);
              if (scrollables.evaluate().isNotEmpty) {
                for (var i = 0; i < 12; i++) {
                  await tester.drag(scrollables.first, const Offset(0, -300), warnIfMissed: false);
                  await tester.pump();
                }
              }

              expect(tester.takeException(), isNull);
            });
          }
        });
      }
    }
  }
}
