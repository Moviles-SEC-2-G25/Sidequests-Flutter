import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'analytics/analytics_tracker.dart';
import 'data/context/context_manager.dart';
import 'data/local/local_data_source.dart';
import 'data/remote/supabase_remote_data_source.dart';
import 'repository/auth_repository.dart';
import 'repository/profile_repository.dart';
import 'repository/quest_repository.dart';
import 'repository/social_repository.dart';
import 'view/auth/auth_gate.dart';
import 'viewmodel/auth/auth_view_model.dart';

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
      sessionId: DateTime.now().microsecondsSinceEpoch.toString(),
    );

    return MultiProvider(
      providers: [
        Provider.value(value: localDataSource),
        Provider.value(value: remoteDataSource),
        Provider.value(value: contextManager),
        Provider.value(value: analyticsTracker),
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
      ],
      child: MaterialApp(
        title: 'Sidequests',
        theme: ThemeData(colorSchemeSeed: Colors.deepPurple, useMaterial3: true),
        home: const AuthGate(),
      ),
    );
  }
}
