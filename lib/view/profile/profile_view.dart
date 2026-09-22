import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
import '../../core/category_labels.dart';
import '../../data/local/local_data_source.dart';
import '../../models/user_preferences.dart';
import '../../viewmodel/auth/auth_view_model.dart';
import '../../viewmodel/profile/profile_view_model.dart';
import '../../viewmodel/quests/quest_view_model.dart';
import '../../viewmodel/theme_view_model.dart';
import 'edit_preferences_view.dart';

/// Profile: header + stats, friends (honest stub — no backend table),
/// rewards/badges (computed live from real `user_quests`, no rewards
/// table exists), preferences, recent completions, published photos
/// (permanently empty — no Storage bucket yet) and settings.
class ProfileView extends StatefulWidget {
  const ProfileView({super.key});

  @override
  State<ProfileView> createState() => _ProfileViewState();
}

class _ProfileViewState extends State<ProfileView> {
  int _friendsTab = 0;
  int _rewardsTab = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ProfileViewModel>().load();
      context.read<QuestViewModel>().load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final profileViewModel = context.watch<ProfileViewModel>();
    final questViewModel = context.watch<QuestViewModel>();

    if (profileViewModel.isLoading && profileViewModel.profile == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          children: [
            _ProfileHeader(profileViewModel: profileViewModel),
            const SizedBox(height: 20),
            _StatsRow(questViewModel: questViewModel),
            const SizedBox(height: 24),
            _FriendsSection(
              tabIndex: _friendsTab,
              onTabChanged: (i) => setState(() => _friendsTab = i),
            ),
            const SizedBox(height: 24),
            _RewardsSection(
              tabIndex: _rewardsTab,
              onTabChanged: (i) => setState(() => _rewardsTab = i),
              questViewModel: questViewModel,
            ),
            const SizedBox(height: 24),
            _PreferencesSection(preferences: profileViewModel.preferences),
            const SizedBox(height: 24),
            _BadgesGrid(questViewModel: questViewModel),
            const SizedBox(height: 24),
            _RecentCompletions(questViewModel: questViewModel),
            const SizedBox(height: 24),
            const _PublishedPhotosSection(),
            const SizedBox(height: 24),
            _SettingsSection(profileViewModel: profileViewModel),
          ],
        ),
      ),
    );
  }
}

class _ProfileHeader extends StatelessWidget {
  final ProfileViewModel profileViewModel;

  const _ProfileHeader({required this.profileViewModel});

  @override
  Widget build(BuildContext context) {
    final name = profileViewModel.profile?.displayName ?? 'Explorador';
    final emailLocalPart = profileViewModel.email?.split('@').first;
    final handle = emailLocalPart != null ? '@$emailLocalPart' : '';
    final initials = name.isNotEmpty ? name[0].toUpperCase() : '🙂';

    return Row(
      children: [
        CircleAvatar(
          radius: 32,
          backgroundColor: AppColors.primaryContainerLight,
          child: Text(initials, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name, style: Theme.of(context).textTheme.titleLarge),
              if (handle.isNotEmpty) Text(handle, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
        IconButton(
          icon: const Icon(Icons.logout),
          tooltip: 'Cerrar sesión',
          onPressed: () => context.read<AuthViewModel>().signOut(),
        ),
      ],
    );
  }
}

class _StatsRow extends StatelessWidget {
  final QuestViewModel questViewModel;

  const _StatsRow({required this.questViewModel});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _StatCard(
            icon: Icons.bolt,
            value: '${questViewModel.completedCount}',
            label: 'Completadas',
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _StatCard(
            icon: Icons.local_fire_department,
            value: '${questViewModel.currentStreakDays}',
            label: 'Racha',
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _StatCard(
            icon: Icons.menu_book,
            value: '${questViewModel.completedCategories.length}',
            label: 'Categorías',
          ),
        ),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;

  const _StatCard({required this.icon, required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: BoxDecoration(color: Theme.of(context).cardColor, borderRadius: BorderRadius.circular(16)),
      child: Column(
        children: [
          Icon(icon, color: AppColors.amber),
          const SizedBox(height: 6),
          Text(value, style: Theme.of(context).textTheme.titleLarge),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

/// Friends UI matching the Figma tab structure, honestly stubbed:
/// Sidequests-Backend has no `friends`/friend-request tables.
class _FriendsSection extends StatelessWidget {
  final int tabIndex;
  final ValueChanged<int> onTabChanged;

  const _FriendsSection({required this.tabIndex, required this.onTabChanged});

  static const _tabs = ['Amigos', 'Solicitudes', 'Agregar'];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Amigos', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 10),
        Row(
          children: List.generate(_tabs.length, (i) {
            return Expanded(
              child: Padding(
                padding: EdgeInsets.only(right: i == _tabs.length - 1 ? 0 : 6),
                child: ChoiceChip(
                  label: Text(_tabs[i]),
                  selected: tabIndex == i,
                  onSelected: (_) => onTabChanged(i),
                ),
              ),
            );
          }),
        ),
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(color: Theme.of(context).cardColor, borderRadius: BorderRadius.circular(16)),
          child: Column(
            children: [
              const Icon(Icons.group_outlined, color: AppColors.primary, size: 32),
              const SizedBox(height: 8),
              Text(
                'Los amigos todavía no están disponibles',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 4),
              Text(
                'El backend compartido aún no tiene tablas de amigos ni solicitudes.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Streak/mission milestones computed live from real `user_quests` data —
/// there is no rewards/badges table in the backend, so nothing here is
/// fetched from a "rewards" endpoint; it's derived client-side from
/// completion history already loaded by QuestViewModel.
class _RewardsSection extends StatelessWidget {
  final int tabIndex;
  final ValueChanged<int> onTabChanged;
  final QuestViewModel questViewModel;

  const _RewardsSection({
    required this.tabIndex,
    required this.onTabChanged,
    required this.questViewModel,
  });

  static const _streakMilestones = [
    (3, 'Primer calentamiento', 'Racha de 3 días seguidos'),
    (7, 'Semana de fuego', 'Racha de 7 días seguidos'),
    (14, 'Constancia quincenal', 'Racha de 14 días seguidos'),
    (30, 'Explorador del mes', 'Racha de 30 días seguidos'),
  ];

  static const _missionMilestones = [
    (1, 'Primeros pasos', 'Completa 1 misión'),
    (5, 'En marcha', 'Completa 5 misiones'),
    (15, 'Explorador habitual', 'Completa 15 misiones'),
    (30, 'Leyenda local', 'Completa 30 misiones'),
  ];

  @override
  Widget build(BuildContext context) {
    final streak = questViewModel.currentStreakDays;
    final completed = questViewModel.completedCount;
    final earnedCount = tabIndex == 0
        ? _streakMilestones.where((m) => streak >= m.$1).length
        : _missionMilestones.where((m) => completed >= m.$1).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Recompensas', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(width: 8),
            _Badge(text: '$earnedCount ganadas', color: AppColors.amber, textColor: Colors.white),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: ChoiceChip(
                label: const Text('🔥 Rachas'),
                selected: tabIndex == 0,
                onSelected: (_) => onTabChanged(0),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ChoiceChip(
                label: const Text('⚡ Misiones'),
                selected: tabIndex == 1,
                onSelected: (_) => onTabChanged(1),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (tabIndex == 0)
          ..._streakMilestones.map(
            (m) => _MilestoneCard(
              threshold: m.$1,
              title: m.$2,
              subtitle: m.$3,
              current: streak,
              unitLabel: 'días',
            ),
          )
        else
          ..._missionMilestones.map(
            (m) => _MilestoneCard(
              threshold: m.$1,
              title: m.$2,
              subtitle: m.$3,
              current: completed,
              unitLabel: 'misiones',
            ),
          ),
      ],
    );
  }
}

class _MilestoneCard extends StatelessWidget {
  final int threshold;
  final String title;
  final String subtitle;
  final int current;
  final String unitLabel;

  const _MilestoneCard({
    required this.threshold,
    required this.title,
    required this.subtitle,
    required this.current,
    required this.unitLabel,
  });

  @override
  Widget build(BuildContext context) {
    final earned = current >= threshold;
    final progress = (current / threshold).clamp(0, 1).toDouble();

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: earned ? AppColors.amber.withValues(alpha: 0.15) : Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: earned
                  ? AppColors.amber
                  : Theme.of(context).colorScheme.outline.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              Icons.local_fire_department,
              color: earned ? Colors.white : Theme.of(context).colorScheme.outline,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleSmall),
                    if (earned) ...[
                      const SizedBox(width: 8),
                      _Badge(text: 'GANADO', color: AppColors.amber, textColor: Colors.white),
                    ],
                  ],
                ),
                Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 6,
                    backgroundColor: AppColors.primaryContainerLight,
                    color: earned ? AppColors.amber : AppColors.primary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${current.clamp(0, threshold)} / $threshold $unitLabel',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PreferencesSection extends StatelessWidget {
  final UserPreferences preferences;

  const _PreferencesSection({required this.preferences});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Mis preferencias', style: Theme.of(context).textTheme.titleLarge),
            TextButton(
              onPressed: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const EditPreferencesView())),
              child: const Text('Editar'),
            ),
          ],
        ),
        Text(
          'INTERESES',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(letterSpacing: 0.5),
        ),
        const SizedBox(height: 8),
        if (preferences.interests.isEmpty)
          Text(
            'Aún no has elegido intereses.',
            style: Theme.of(context).textTheme.bodySmall,
          )
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: preferences.interests
                .map((interest) => Chip(label: Text(categoryLabelEs(interest))))
                .toList(),
          ),
      ],
    );
  }
}

/// Computed from `user_quests` + the quest catalogue — no badges table
/// exists, so "earned" is a real boolean derived from completion history.
class _BadgesGrid extends StatelessWidget {
  final QuestViewModel questViewModel;

  const _BadgesGrid({required this.questViewModel});

  @override
  Widget build(BuildContext context) {
    final badges = [
      ('⚡', 'Primera misión', questViewModel.badgeFirstMission),
      ('🧭', 'Explorador/a', questViewModel.badgeExplorer),
      ('☕', 'Gourmet', questViewModel.badgeGourmet),
      ('🎨', 'Amante del arte', questViewModel.badgeArtLover),
      ('🔥', 'Racha de 7 días', questViewModel.badgeSevenDayStreak),
      ('📚', 'Ratón de biblioteca', questViewModel.badgeBookworm),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Insignias', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 10),
        GridView.count(
          crossAxisCount: 3,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 0.95,
          children: badges.map((badge) {
            final (emoji, label, earned) = badge;
            return Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: earned
                    ? Theme.of(context).cardColor
                    : Theme.of(context).cardColor.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Opacity(
                    opacity: earned ? 1 : 0.35,
                    child: Text(emoji, style: const TextStyle(fontSize: 24)),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    label,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: earned ? null : Theme.of(context).colorScheme.outline,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Icon(
                    earned ? Icons.check_circle : Icons.lock_outline,
                    size: 14,
                    color: earned ? AppColors.secondary : Theme.of(context).colorScheme.outline,
                  ),
                ],
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}

class _RecentCompletions extends StatelessWidget {
  final QuestViewModel questViewModel;

  const _RecentCompletions({required this.questViewModel});

  @override
  Widget build(BuildContext context) {
    final recent = questViewModel.completedQuests.take(5).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Completadas recientemente', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 10),
        if (recent.isEmpty)
          Text(
            'Todavía no has completado ninguna misión.',
            style: Theme.of(context).textTheme.bodySmall,
          )
        else
          ...recent.map((userQuest) {
            final quest = questViewModel.questById(userQuest.questId);
            final date = userQuest.completedAt;
            return Card(
              margin: const EdgeInsets.only(bottom: 10),
              child: ListTile(
                leading: Text(quest?.emoji ?? '🎯', style: const TextStyle(fontSize: 20)),
                title: Text(quest?.title ?? userQuest.questId),
                subtitle: Text(
                  [
                    if (date != null) _formatShortDate(date),
                    if (quest != null) categoryLabelEs(quest.category),
                    if (quest != null) '${quest.durationMinutes} min',
                  ].join(' · '),
                ),
                trailing: const Icon(Icons.check_circle, color: AppColors.secondary),
              ),
            );
          }),
      ],
    );
  }
}

/// Always empty: Sidequests-Backend has no Storage bucket yet, so a
/// completed quest's photo can never actually be shared here.
class _PublishedPhotosSection extends StatelessWidget {
  const _PublishedPhotosSection();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Fotos publicadas', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 10),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(color: Theme.of(context).cardColor, borderRadius: BorderRadius.circular(16)),
          child: Column(
            children: [
              Icon(Icons.camera_alt_outlined, size: 32, color: Theme.of(context).colorScheme.outline),
              const SizedBox(height: 10),
              Text('Aún no has publicado fotos', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              Text(
                'Al completar una misión, activa "Compartir en Social" para que aparezca aquí.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SettingsSection extends StatefulWidget {
  final ProfileViewModel profileViewModel;

  const _SettingsSection({required this.profileViewModel});

  @override
  State<_SettingsSection> createState() => _SettingsSectionState();
}

class _SettingsSectionState extends State<_SettingsSection> {
  late bool _missionNotifications;
  late bool _dailyReminders;

  @override
  void initState() {
    super.initState();
    final localDataSource = context.read<LocalDataSource>();
    _missionNotifications = localDataSource.missionNotificationsEnabled();
    _dailyReminders = localDataSource.dailyRemindersEnabled();
  }

  @override
  Widget build(BuildContext context) {
    final themeViewModel = context.watch<ThemeViewModel>();
    final localDataSource = context.read<LocalDataSource>();
    final profile = widget.profileViewModel.profile;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Ajustes', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        _SettingSwitch(
          title: 'Modo oscuro',
          subtitle: 'Más cómodo para los ojos',
          value: themeViewModel.isDarkMode,
          onChanged: themeViewModel.setDarkMode,
        ),
        _SettingSwitch(
          title: 'Notificaciones de misiones',
          subtitle: 'Alertas de misiones cercanas — aún sin push real (FCM pendiente)',
          value: _missionNotifications,
          onChanged: (value) {
            setState(() => _missionNotifications = value);
            localDataSource.setMissionNotificationsEnabled(value);
          },
        ),
        _SettingSwitch(
          title: 'Recordatorios diarios',
          subtitle: 'Un recordatorio amable — aún sin push real (FCM pendiente)',
          value: _dailyReminders,
          onChanged: (value) {
            setState(() => _dailyReminders = value);
            localDataSource.setDailyRemindersEnabled(value);
          },
        ),
        const SizedBox(height: 4),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Correo'),
          trailing: Text(widget.profileViewModel.email ?? '—'),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Miembro desde'),
          trailing: Text(
            profile?.createdAt != null ? _formatMonthYear(profile!.createdAt!) : '—',
          ),
        ),
      ],
    );
  }
}

class _SettingSwitch extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SettingSwitch({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
      value: value,
      onChanged: onChanged,
    );
  }
}

class _Badge extends StatelessWidget {
  final String text;
  final Color color;
  final Color? textColor;

  const _Badge({required this.text, required this.color, this.textColor});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(20)),
      child: Text(text, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: textColor)),
    );
  }
}

const _monthNamesEs = [
  'Enero', 'Febrero', 'Marzo', 'Abril', 'Mayo', 'Junio',
  'Julio', 'Agosto', 'Septiembre', 'Octubre', 'Noviembre', 'Diciembre',
];

const _monthAbbrEs = ['Ene', 'Feb', 'Mar', 'Abr', 'May', 'Jun', 'Jul', 'Ago', 'Sep', 'Oct', 'Nov', 'Dic'];

String _formatMonthYear(DateTime date) => '${_monthNamesEs[date.month - 1]} ${date.year}';

String _formatShortDate(DateTime date) => '${_monthAbbrEs[date.month - 1]} ${date.day}';
