import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sqflite/sqflite.dart' show databaseFactorySqflitePlugin;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'analytics/analytics_tracker.dart';
import 'core/app_theme.dart';
import 'core/completion_likelihood.dart';
import 'core/workers/similar_quest_worker.dart';
import 'data/cache/byte_lru_cache.dart';
import 'data/context/context_manager.dart';
import 'data/local/local_data_source.dart';
import 'data/local/offline_pack_manifest_store.dart';
import 'data/local/step_log_database.dart';
import 'data/remote/network_guard.dart';
import 'data/remote/supabase_remote_data_source.dart';
import 'data/services/biometric_service.dart';
import 'data/services/location_service.dart';
import 'data/services/reverse_geocoding_service.dart';
import 'data/offline/offline_pack_manager.dart';
import 'data/services/weather_service.dart';
import 'repository/auth_repository.dart';
import 'repository/evidence_repository.dart';
import 'repository/group_challenge_repository.dart';
import 'repository/profile_repository.dart';
import 'repository/quest_repository.dart';
import 'repository/social_repository.dart';
import 'view/auth/auth_gate.dart';
import 'viewmodel/auth/auth_view_model.dart';
import 'viewmodel/context/connectivity_view_model.dart';
import 'viewmodel/offline/offline_pack_view_model.dart';
import 'viewmodel/profile/stats_view_model.dart';
import 'viewmodel/profile/profile_view_model.dart';
import 'viewmodel/quests/quest_view_model.dart';
import 'viewmodel/social/social_view_model.dart';
import 'viewmodel/theme_view_model.dart';

/// Composition root: wires data sources -> repositories -> ViewModels.
/// The architecture marks a dedicated DI container as {planned}; today this
/// function is that wiring step.
class SidequestsApp extends StatelessWidget {
  final LocalDataSource localDataSource;

  /// One for the whole app (SQLite), shared by the repositories that write,
  /// read and clear it. null on the web build, which has no sqflite.
  final StepLogDatabase? stepLog;

  /// Caching strategy: memoized results for the whole session, created once
  /// here (StatsViewModel is created on every visit to its screen) and emptied
  /// on sign-out by AuthRepository.
  final completionLikelihoodMemo = CompletionLikelihoodMemo();
  final statsSummaryCache = StatsSummaryCache();

  /// Multithreading strategy: the "Te podría gustar" worker isolate. Owned
  /// here, not by QuestViewModel, so signing out (AuthRepository) kills it
  /// too; it only spawns the first time a completed mission needs it.
  final similarQuestWorker = SimilarQuestWorker();

  /// Caching strategy (Alejandro, Sprint 4): the in-memory level of
  /// "Evidencias de un intento", bounded in bytes. Owned here so sign-out
  /// (AuthRepository) empties them; the disk level is LocalDataSource's
  /// EvidenceStore, cleared in LocalDataSource.clear().
  final evidenceThumbnailCache = ByteLruCache<String>(maxBytes: kEvidenceThumbnailCacheBytes);
  final evidencePhotoCache = ByteLruCache<String>(maxBytes: kEvidencePhotoCacheBytes);

  SidequestsApp({super.key, required this.localDataSource, StepLogDatabase? stepLog})
    : stepLog = stepLog ?? (kIsWeb ? null : StepLogDatabase(factory: databaseFactorySqflitePlugin));

  @override
  Widget build(BuildContext context) {
    final remoteDataSource = SupabaseRemoteDataSource(Supabase.instance.client);
    final network = NetworkGuard.connectivity();
    // Shared with ContextManager below so the "Clima en el lugar" card and
    // every context snapshot (recommendations, analytics) hit the same
    // cache instead of each keeping a separate one.
    final weatherService = WeatherService(localDataSource: localDataSource);
    // Same idea for the GPS: one LocationService, so its PositionCache serves
    // the snapshots and the weather card alike, and sign-out clears that one.
    final locationService = LocationService();
    final contextManager = ContextManager(
      locationService: locationService,
      weatherService: weatherService,
    );
    final analyticsTracker = AnalyticsTracker(
      eventSink: remoteDataSource,
      contextManager: contextManager,
      // analytics_events.session_id is a Postgres `uuid` column; a
      // non-uuid value here makes every event insert fail RLS/type
      // validation silently (AnalyticsTracker.track swallows the error).
      sessionId: const Uuid().v4(),
      // Offline queue: failed inserts wait here until the next one succeeds.
      localDataSource: localDataSource,
    );

    return MultiProvider(
      providers: [
        Provider.value(value: localDataSource),
        Provider.value(value: remoteDataSource),
        Provider.value(value: contextManager),
        Provider.value(value: analyticsTracker),
        Provider(create: (_) => BiometricService()),
        Provider.value(value: locationService),
        Provider.value(value: weatherService),
        Provider.value(value: statsSummaryCache),
        Provider(
          create: (_) => ReverseGeocodingService(localDataSource: localDataSource),
        ),
        Provider(
          create: (_) => ProfileRepository(remoteDataSource, localDataSource, network: network),
        ),
        Provider(
          create: (_) =>
              QuestRepository(remoteDataSource, localDataSource, network: network, stepLog: stepLog),
        ),
        // Offline pack: its manifest + the steps pre-loaded through QuestRepository.
        Provider(
          create: (context) =>
              OfflinePackManager(context.read<QuestRepository>(), OfflinePackManifestStore()),
        ),
        // After the offline pack: signing out clears its manifest too.
        Provider(
          create: (context) => AuthRepository(
            remoteDataSource,
            localDataSource,
            stepLog: stepLog,
            sessionCaches: [
              completionLikelihoodMemo,
              statsSummaryCache,
              locationService.positionCache,
              evidenceThumbnailCache,
              evidencePhotoCache,
            ],
            offlinePack: context.read<OfflinePackManager>(),
          ),
        ),
        Provider(create: (_) => SocialRepository()),
        Provider(
          create: (_) => GroupChallengeRepository(remoteDataSource, localDataSource, network: network),
        ),
        Provider(
          create: (_) =>
              QuestRepository(remoteDataSource, localDataSource, network: network, stepLog: stepLog),
        ),
        Provider(
          create: (context) => EvidenceRepository(
            context.read<QuestRepository>(),
            remoteDataSource,
            localDataSource,
            network: network,
            thumbnailCache: evidenceThumbnailCache,
            photoCache: evidencePhotoCache,
          ),
        ),
        Provider(create: (_) => SocialRepository()),
        ChangeNotifierProvider(
          create: (context) => AuthViewModel(
            context.read<AuthRepository>(),
            context.read<BiometricService>(),
            analyticsTracker,
          ),
        ),
        ChangeNotifierProvider(create: (_) => ThemeViewModel(localDataSource)),
        // Above MaterialApp so every route, including login and the screens
        // pushed over HomeShell, can block what needs the internet.
        ChangeNotifierProvider(create: (_) => ConnectivityViewModel()),
        ChangeNotifierProvider(
          create: (context) => OfflinePackViewModel(context.read<OfflinePackManager>()),
        ),
        // Below providers depend on a signed-in userId. Provider's `create`
        // is lazy (runs on first read), and these are only ever read from
        // inside HomeShell (reachable only once authenticated), so reading
        // AuthViewModel.userId here is safe despite it being null pre-login.
        // Placed above MaterialApp/Navigator (not inside HomeShell) so any
        // route pushed on top of HomeShell can still see them.
        ChangeNotifierProvider(
          create: (context) => QuestViewModel(
            context.read<QuestRepository>(),
            contextManager,
            analyticsTracker,
            context.read<AuthViewModel>().userId!,
            initialFilters: context.read<QuestRepository>().getExploreFilters(),
            completionLikelihoodMemo: completionLikelihoodMemo,
            similarQuestRunner: similarQuestWorker,
          ),
        ),
        ChangeNotifierProvider(
          create: (context) => ProfileViewModel(
            context.read<ProfileRepository>(),
            context.read<AuthRepository>(),
            context.read<AuthViewModel>().userId!,
          ),
        ),
        ChangeNotifierProvider(
          create: (context) => SocialViewModel(context.read<SocialRepository>()),
        ),
      ],
      child: Consumer<ThemeViewModel>(
        builder: (context, themeViewModel, _) => MaterialApp(
          title: 'Sidequests',
          // No "DEBUG" ribbon on the build that gets installed and graded.
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: themeViewModel.themeMode,
          home: const AuthGate(),
        ),
      ),
    );
  }
}
