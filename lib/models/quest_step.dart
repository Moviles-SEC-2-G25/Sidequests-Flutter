/// Mirrors `public.quest_steps`.
class QuestStep {
  final int id;
  final String questId;
  final int stepOrder;
  final String title;
  final String description;
  final String verificationType; // none | photo | location | photo_and_location

  const QuestStep({
    required this.id,
    required this.questId,
    required this.stepOrder,
    required this.title,
    this.description = '',
    this.verificationType = 'none',
  });

  factory QuestStep.fromJson(Map<String, dynamic> json) => QuestStep(
    id: json['id'] as int,
    questId: json['quest_id'] as String,
    stepOrder: json['step_order'] as int,
    title: json['title'] as String,
    description: json['description'] as String? ?? '',
    verificationType: json['verification_type'] as String? ?? 'none',
  );
}
