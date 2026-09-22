import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/quest.dart';
import '../../viewmodel/quests/quest_view_model.dart';
import 'quest_detail_view.dart';

/// Explore / quest list. Recommendations and quest detail/mission-in-progress
/// live behind this same ViewModel; this view covers the catalog browse path.
class QuestListView extends StatefulWidget {
  const QuestListView({super.key});

  @override
  State<QuestListView> createState() => _QuestListViewState();
}

class _QuestListViewState extends State<QuestListView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => context.read<QuestViewModel>().load(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final questViewModel = context.watch<QuestViewModel>();

    return Scaffold(
      appBar: AppBar(title: const Text('Explore')),
      body: RefreshIndicator(
        onRefresh: questViewModel.load,
        child: _buildBody(context, questViewModel),
      ),
    );
  }

  Widget _buildBody(BuildContext context, QuestViewModel questViewModel) {
    if (questViewModel.isLoading && questViewModel.catalog.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (questViewModel.errorMessage != null && questViewModel.catalog.isEmpty) {
      return Center(child: Text(questViewModel.errorMessage!));
    }
    if (questViewModel.catalog.isEmpty) {
      return const Center(child: Text('No quests available right now.'));
    }
    return ListView.builder(
      itemCount: questViewModel.catalog.length,
      itemBuilder: (context, index) => _QuestTile(quest: questViewModel.catalog[index]),
    );
  }
}

class _QuestTile extends StatelessWidget {
  final Quest quest;

  const _QuestTile({required this.quest});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Text(quest.emoji ?? '🎯', style: const TextStyle(fontSize: 24)),
      title: Text(quest.title),
      subtitle: Text('${quest.category} · ${quest.durationMinutes} min · ${quest.difficulty}'),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => QuestDetailView(quest: quest)),
      ),
    );
  }
}
