import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'analytics/analytics_tracker.dart';
import 'core/app_theme.dart';
import 'data/context/context_manager.dart';
import 'data/local/local_data_source.dart';
import 'data/remote/supabase_remote_data_source.dart';
import 'data/services/location_service.dart';
import 'data/services/weather_service.dart';
import 'repository/auth_repository.dart';
import 'repository/profile_repository.dart';
import 'repository/quest_repository.dart';
import 'repository/social_repository.dart';
import 'view/auth/auth_gate.dart';
import 'viewmodel/auth/auth_view_model.dart';
import 'viewmodel/profile/profile_view_model.dart';
import 'viewmodel/quests/quest_view_model.dart';
import 'viewmodel/social/social_view_model.dart';
import 'viewmodel/theme_view_model.dart';

/// Composition root: wires data sources -> repositories -> ViewModels.
/// The architecture marks a dedicated DI container as {planned}; today this
/// function is that wiring step.
class SidequestsApp extends StatelessWidget {
  final LocalDataSource localDataSource;

  const SidequestsApp({super.key, required this.localDataSource});

  @override
  Widget build(BuildContext context) {
    final remoteDataSource = SupabaseRemoteDataSource(Supabase.instance.client);
    final contextManager = ContextManager();
    final analyticsTracker = AnalyticsTracker(
      eventSink: remoteDataSource,
      contextManager: contextManager,
      // analytics_events.session_id is a Postgres `uuid` column; a
      // non-uuid value here makes every event insert fail RLS/type
      // validation silently (AnalyticsTracker.track swallows the error).
      sessionId: const Uuid().v4(),
    );

    return MultiProvider(
      providers: [
        Provider.value(value: localDataSource),
        Provider.value(value: remoteDataSource),
        Provider.value(value: contextManager),
        Provider.value(value: analyticsTracker),
        Provider(create: (_) => LocationService()),
        Provider(create: (_) => WeatherService()),
        Provider(
          create: (_) => AuthRepository(remoteDataSource, localDataSource),
        ),
        Provider(
          create: (_) => ProfileRepository(remoteDataSource, localDataSource),
        ),
        Provider(
          create: (_) => QuestRepository(remoteDataSource, localDataSource),
        ),
        Provider(create: (_) => SocialRepository()),
        ChangeNotifierProvider(
          create: (context) => AuthViewModel(
            context.read<AuthRepository>(),
            analyticsTracker,
          ),
        ),
        ChangeNotifierProvider(create: (_) => ThemeViewModel(localDataSource)),
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
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: themeViewModel.themeMode,
          home: const AuthGate(),
        ),
      ),
    );
  }
}
