import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/quest.dart';
import '../../models/user_quest.dart';
import '../../viewmodel/quests/quest_view_model.dart';

/// Quest detail / mission-in-progress. Renders quest info and, once the
/// user has accepted it, the abandon/complete actions.
class QuestDetailView extends StatelessWidget {
  final Quest quest;

  const QuestDetailView({super.key, required this.quest});

  @override
  Widget build(BuildContext context) {
    final questViewModel = context.watch<QuestViewModel>();
    final UserQuest? userQuest = questViewModel.userQuests
        .cast<UserQuest?>()
        .firstWhere((uq) => uq?.questId == quest.id, orElse: () => null);
    final isActive = userQuest != null &&
        (userQuest.status == 'accepted' || userQuest.status == 'in_progress');

    return Scaffold(
      appBar: AppBar(title: Text(quest.title)),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(quest.description),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                Chip(label: Text('${quest.durationMinutes} min')),
                Chip(label: Text(quest.difficulty)),
                Chip(label: Text(quest.socialLevel)),
                if (quest.estimatedCost > 0) Chip(label: Text('\$${quest.estimatedCost}')),
              ],
            ),
            const Spacer(),
            if (!isActive)
              FilledButton(
                onPressed: () => questViewModel.acceptQuest(quest.id),
                child: const Text('Accept quest'),
              )
            else ...[
              FilledButton(
                onPressed: () => questViewModel.completeQuest(userQuest),
                child: const Text('Mark as completed'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () => questViewModel.abandonQuest(
                  userQuest,
                  reason: 'user_abandoned',
                ),
                child: const Text('Abandon'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
