import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
import '../../core/category_labels.dart';
import '../../models/user_preferences.dart';
import '../../viewmodel/auth/auth_view_model.dart';
import '../../viewmodel/profile/profile_view_model.dart';
import '../../viewmodel/quests/quest_view_model.dart';
import '../../viewmodel/theme_view_model.dart';
import '../widgets/offline_notice.dart';
import '../widgets/sq_components.dart';
import 'change_password_dialog.dart';
import 'edit_preferences_view.dart';
import 'mission_history_view.dart';
import 'offline_pack_view.dart';
import 'stats_view.dart';

/// Profile, laid out like the Kotlin app's ProfileScreen: header with the
/// theme toggle, accent stats, theme, interests, difficulty, social vibe,
/// account, biometric unlock, offline access, mission history, badges and
/// sign out — 16 dp apart. Preferences are changed in EditPreferencesView
/// (they're saved on the server), so tapping a preference chip opens it.
class ProfileView extends StatefulWidget {
  const ProfileView({super.key});

  @override
  State<ProfileView> createState() => _ProfileViewState();
}

class _ProfileViewState extends State<ProfileView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ProfileViewModel>().load();
      context.read<QuestViewModel>().load();
      context.read<AuthViewModel>().loadBiometricAvailability();
    });
  }

  @override
  Widget build(BuildContext context) {
    final profileViewModel = context.watch<ProfileViewModel>();
    final questViewModel = context.watch<QuestViewModel>();

    if (profileViewModel.isLoading && profileViewModel.profile == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final sections = <Widget>[
      _ProfileHeader(profileViewModel: profileViewModel),
      _StatsRow(questViewModel: questViewModel),
      const _ThemeSection(),
      _PreferencesSection(preferences: profileViewModel.preferences),
      _AccountSection(profileViewModel: profileViewModel),
      const _BiometricSection(),
      const _OfflineAccessSection(),
      _LinkRow(
        title: 'Mission History',
        action: 'View history',
        onTap: () => Navigator.of(context).push(MissionHistoryView.route()),
      ),
      _BadgesSection(questViewModel: questViewModel),
      const _SignOutButton(),
    ];

    return Scaffold(
      body: SafeArea(
        child: ListView.separated(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
          itemCount: sections.length,
          separatorBuilder: (_, _) => const SizedBox(height: 16),
          itemBuilder: (_, index) => sections[index],
        ),
      ),
    );
  }
}

/// Kotlin's faded uppercase section label ("THEME", "ACCOUNT"…).
class _Label extends StatelessWidget {
  final String text;

  const _Label(this.text);

  @override
  Widget build(BuildContext context) => SqSectionLabel(text);
}

class _ProfileHeader extends StatelessWidget {
  final ProfileViewModel profileViewModel;

  const _ProfileHeader({required this.profileViewModel});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final themeViewModel = context.watch<ThemeViewModel>();
    final displayName = profileViewModel.profile?.displayName?.trim();
    final name = (displayName?.isNotEmpty ?? false) ? displayName! : 'Explorer';
    final emailLocalPart = profileViewModel.email?.split('@').first;

    return Row(
      children: [
        Container(
          width: 64,
          height: 64,
          alignment: Alignment.center,
          decoration: BoxDecoration(shape: BoxShape.circle, color: scheme.primaryContainer),
          child: Text(
            (displayName?.isNotEmpty ?? false) ? displayName![0].toUpperCase() : '🧭',
            style: const TextStyle(fontSize: 26),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name, style: Theme.of(context).textTheme.titleLarge),
              if (emailLocalPart != null)
                Text(
                  '@$emailLocalPart',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: scheme.onSurface.withValues(alpha: .55),
                  ),
                ),
            ],
          ),
        ),
        SqCircleButton(
          glyph: themeViewModel.isDarkMode ? '☀️' : '🌙',
          tooltip: themeViewModel.isDarkMode ? 'Light mode' : 'Dark mode',
          onTap: () => themeViewModel.setDarkMode(!themeViewModel.isDarkMode),
        ),
      ],
    );
  }
}

/// Kotlin's AccentStat row and "View my stats".
class _StatsRow extends StatelessWidget {
  final QuestViewModel questViewModel;

  const _StatsRow({required this.questViewModel});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 9,
          runSpacing: 8,
          children: [
            SqAccentStat(
              label: 'Completed',
              value: '${questViewModel.completedCount}',
              emoji: '⚡',
              color: Theme.of(context).colorScheme.primary,
            ),
            SqAccentStat(label: 'Attempted', value: '${questViewModel.userQuests.length}', emoji: '✓'),
            SqAccentStat(
              label: 'Day streak',
              value: '${questViewModel.currentStreakDays}',
              emoji: '🔥',
              color: AppColors.amber,
            ),
          ],
        ),
        TextButton(
          onPressed: () => Navigator.of(context).push(StatsView.route()),
          child: const Text('View my stats'),
        ),
      ],
    );
  }
}

class _ThemeSection extends StatelessWidget {
  const _ThemeSection();

  @override
  Widget build(BuildContext context) {
    final themeViewModel = context.watch<ThemeViewModel>();
    final faded = Theme.of(context).colorScheme.onSurface.withValues(alpha: .55);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _Label('THEME'),
        const SizedBox(height: 9),
        Text(
          themeViewModel.isDarkMode
              ? 'Dark mode is on. Tap the sun to switch back to light.'
              : 'Tap the moon/sun to choose the theme manually.',
          style: TextStyle(fontSize: 12, color: faded),
        ),
      ],
    );
  }
}

/// Kotlin's YOUR INTERESTS / DIFFICULTY / SOCIAL VIBE chip groups.
class _PreferencesSection extends StatelessWidget {
  final UserPreferences preferences;

  const _PreferencesSection({required this.preferences});

  static String _capitalize(String value) => value.isEmpty ? value : value[0].toUpperCase() + value.substring(1);

  @override
  Widget build(BuildContext context) {
    void edit(bool _) =>
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => const EditPreferencesView()));

    Widget group(String label, List<Widget> chips, {double gap = 9}) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Label(label),
        SizedBox(height: gap),
        Wrap(spacing: 8, runSpacing: 8, children: chips),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        group('YOUR INTERESTS', gap: 10, [
          for (final interest in kInterestOptions)
            SqChoiceChip(
              label: categoryLabelEs(interest),
              selected: preferences.interests.contains(interest),
              onSelected: edit,
            ),
        ]),
        const SizedBox(height: 16),
        group('DIFFICULTY', [
          for (final difficulty in const ['easy', 'medium', 'hard'])
            SqChoiceChip(
              label: _capitalize(difficulty),
              selected: preferences.preferredDifficulty == difficulty,
              onSelected: edit,
            ),
        ]),
        const SizedBox(height: 16),
        group('SOCIAL VIBE', [
          for (final level in const ['solo', 'social', 'group'])
            SqChoiceChip(
              label: _capitalize(level),
              selected: preferences.socialLevel == level,
              selectedColor: AppColors.secondary,
              onSelected: edit,
            ),
        ]),
        TextButton(
          onPressed: () => edit(true),
          child: const Text('Edit preferences'),
        ),
      ],
    );
  }
}

class _AccountSection extends StatelessWidget {
  final ProfileViewModel profileViewModel;

  const _AccountSection({required this.profileViewModel});

  /// Needs the server: offline it says so instead of opening a form that
  /// can only fail.
  void _changePassword(BuildContext context) {
    if (readIsOffline(context)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(AuthViewModel.offlinePasswordMessage)),
      );
      return;
    }
    showChangePasswordDialog(context);
  }

  @override
  Widget build(BuildContext context) {
    final profile = profileViewModel.profile;
    final faded = Theme.of(context).colorScheme.onSurface.withValues(alpha: .65);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _Label('ACCOUNT'),
        Text(
          profileViewModel.email ?? 'Authenticated user',
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: faded),
        ),
        if (profile?.createdAt != null)
          Text(
            'Member since ${_formatMonthYear(profile!.createdAt!)}',
            style: TextStyle(fontSize: 12, color: faded),
          ),
        const SizedBox(height: 8),
        FilledButton(onPressed: () => _changePassword(context), child: const Text('Change password')),
      ],
    );
  }
}

/// Kotlin's "Biometric unlock" block. Sensor and local flag only: works the
/// same without a connection.
class _BiometricSection extends StatelessWidget {
  const _BiometricSection();

  Future<void> _toggle(BuildContext context, bool value) async {
    final authViewModel = context.read<AuthViewModel>();
    if (!value) return authViewModel.disableBiometric();
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await authViewModel.enableBiometric();
    if (!confirmed) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not verify your fingerprint. Unlock was not enabled.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final authViewModel = context.watch<AuthViewModel>();
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Biometric unlock', style: textTheme.titleMedium),
        if (authViewModel.isBiometricAvailable)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Unlock with fingerprint'),
            subtitle: Text(
              authViewModel.biometricEnabled
                  ? 'Enabled for this account on this device.'
                  : 'Use biometrics to open your saved session.',
              style: textTheme.bodySmall,
            ),
            value: authViewModel.biometricEnabled,
            onChanged: (value) => _toggle(context, value),
          )
        else
          Text('Set up a supported biometric in your device settings.', style: textTheme.bodySmall),
      ],
    );
  }
}

/// Entry to the offline pack (Kotlin's OFFLINE ACCESS).
class _OfflineAccessSection extends StatelessWidget {
  const _OfflineAccessSection();

  @override
  Widget build(BuildContext context) {
    final faded = Theme.of(context).colorScheme.onSurface.withValues(alpha: .65);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _Label('OFFLINE ACCESS'),
        const SizedBox(height: 6),
        Text(
          'Keep selected quests and their steps available when you lose your connection.',
          style: TextStyle(fontSize: 12, color: faded),
        ),
        const SizedBox(height: 6),
        TextButton(
          onPressed: () => Navigator.of(context).push(OfflinePackView.route()),
          child: const Text('Manage Offline Pack  →'),
        ),
      ],
    );
  }
}

/// "Mission History · View history" (and other title + action rows).
class _LinkRow extends StatelessWidget {
  final String title;
  final String action;
  final VoidCallback onTap;

  const _LinkRow({required this.title, required this.action, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
        TextButton(onPressed: onTap, child: Text(action)),
      ],
    );
  }
}

/// Kotlin's three BADGES cards, tinted by their accent. Whether each one is
/// earned is computed from the real completion history; locked ones fade.
class _BadgesSection extends StatelessWidget {
  final QuestViewModel questViewModel;

  const _BadgesSection({required this.questViewModel});

  @override
  Widget build(BuildContext context) {
    final badges = [
      ('⚡', 'First Quest', AppColors.primary, questViewModel.badgeFirstMission),
      ('🧭', 'Explorer', AppColors.secondary, questViewModel.badgeExplorer),
      ('🔥', '7-Day Streak', AppColors.amber, questViewModel.badgeSevenDayStreak),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _Label('BADGES'),
        const SizedBox(height: 16),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (index, (emoji, label, color, earned)) in badges.indexed) ...[
                if (index > 0) const SizedBox(width: 8),
                Expanded(
                  child: Opacity(
                    opacity: earned ? 1 : .45,
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: .12),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Column(
                        children: [
                          Text(emoji, style: const TextStyle(fontSize: 26)),
                          Text(
                            label,
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700),
                          ),
                          if (!earned) ...[
                            const SizedBox(height: 2),
                            const Icon(Icons.lock_outline, size: 12),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Kotlin's red "Sign out" PrimaryButton.
class _SignOutButton extends StatelessWidget {
  const _SignOutButton();

  /// Signing out works offline, but the way back in doesn't, and what's still
  /// waiting to sync is cleared with the rest of the account's data: offline,
  /// it asks first.
  Future<void> _signOut(BuildContext context) async {
    final authViewModel = context.read<AuthViewModel>();
    if (readIsOffline(context)) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text("You're offline"),
          content: const Text(
            'If you log out now you will not be able to log back in until you reconnect, '
            'and any changes that have not synced yet will be lost. '
            'Log out anyway?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Log out'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    await authViewModel.signOut();
  }

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      style: sqPrimaryButtonStyle(Theme.of(context).colorScheme.error),
      onPressed: () => _signOut(context),
      child: const Text('Sign out'),
    );
  }
}

const _monthNames = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

String _formatMonthYear(DateTime date) => '${_monthNames[date.month - 1]} ${date.year}';
