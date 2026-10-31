import '../models/abandonment_reason.dart';
import '../models/app_context.dart';
import '../models/quest.dart';
import '../models/user_preferences.dart';
import 'bq10_context.dart';
import 'distance.dart';

/// Same version as Kotlin: both apps apply the same rules.
const questAlternativesAlgorithmVersion = 'lex_alternatives_v1';

/// ContextManager.rainFallbackMaxAge: past it, the last known weather no
/// longer says anything about right now.
const _weatherMaxAge = Duration(hours: 3);

const _indoorTags = {'indoor', 'home', 'digital'};
const _outdoorTags = {'outdoor', 'park', 'hiking', 'walking', 'nature', 'cycling', 'running'};
const _calmTags = {'calm', 'chill', 'creative'};
const _morningTags = {'coffee', 'learning', 'movement'};
const _eveningTags = {'food', 'art', 'social'};

/// clear | cloudy | rain | snow | storm | unknown, the way the alternatives
/// read it: a last known weather that's too old counts as unknown.
String alternativesWeatherCondition(AppContext context) {
  final age = context.weatherAge;
  if (age != null && age >= _weatherMaxAge) return 'unknown';
  return weatherConditionFor(context);
}

class QuestAlternative {
  final Quest quest;
  final int score;
  final List<String> explanations;
  final List<String> ruleCodes;

  const QuestAlternative({
    required this.quest,
    required this.score,
    required this.explanations,
    required this.ruleCodes,
  });
}

/// Kotlin's QuestAlternativeRecommender, independent of the shared BQ5 ranking:
/// same filters and points. The one difference is "too far": Flutter's quests
/// have no catalogue distance label, so "closer" means closer to the user by
/// GPS; without a position nothing counts as closer.
class QuestAlternativeRecommender {
  const QuestAlternativeRecommender();

  List<QuestAlternative> recommend({
    required List<Quest> catalog,
    required Quest abandonedQuest,
    required AbandonmentReason reason,
    required AppContext context,
    required int availableMinutes,
    required UserPreferences preferences,
    Set<String> excludedIds = const {},
    int limit = 3,
  }) {
    if (limit <= 0 || availableMinutes <= 0) return const [];
    final seenIds = <String>{};
    final alternatives = [
      for (final quest in catalog)
        if (seenIds.add(quest.id) &&
            quest.id != abandonedQuest.id &&
            !excludedIds.contains(quest.id) &&
            quest.durationMinutes >= 1 &&
            quest.durationMinutes <= availableMinutes &&
            _budget(quest) >= 0 &&
            _budget(quest) <= preferences.budgetMax &&
            (preferences.locationMode != 'anywhere' || _isAnywhere(quest)) &&
            _improvesReason(quest, abandonedQuest, reason, context))
          _score(quest, reason, context, preferences),
    ];
    alternatives.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      final byDuration = a.quest.durationMinutes.compareTo(b.quest.durationMinutes);
      if (byDuration != 0) return byDuration;
      final byBudget = _budget(a.quest).compareTo(_budget(b.quest));
      if (byBudget != 0) return byBudget;
      return a.quest.id.compareTo(b.quest.id);
    });
    return alternatives.take(limit).toList();
  }

  bool _improvesReason(Quest candidate, Quest source, AbandonmentReason reason, AppContext context) {
    switch (reason) {
      case AbandonmentReason.ranOutOfTime:
        return candidate.durationMinutes < source.durationMinutes;
      case AbandonmentReason.tooExpensive:
        return _budget(candidate) < _budget(source);
      case AbandonmentReason.tooFar:
        if (_isAnywhere(candidate)) return true;
        final previous = _gpsDistance(source, context);
        final distance = _gpsDistance(candidate, context);
        return previous != null && distance != null && distance < previous;
      case AbandonmentReason.tooDifficult:
        return _difficultyRank(candidate.difficulty) < _difficultyRank(source.difficulty);
      case AbandonmentReason.placeUnavailable:
        return _isAnywhere(candidate);
      case AbandonmentReason.weatherOrMoodChanged:
      case AbandonmentReason.other:
        return true;
    }
  }

  QuestAlternative _score(
    Quest quest,
    AbandonmentReason reason,
    AppContext context,
    UserPreferences preferences,
  ) {
    var points = 0;
    final explanations = <String>[];
    final rules = <String>[];
    final tags = quest.tags.map((tag) => tag.toLowerCase()).toSet();
    final noTravel = _isAnywhere(quest);
    final indoor = tags.any(_indoorTags.contains);
    final outdoor = tags.any(_outdoorTags.contains);

    void reward(int value, String code, String explanation) {
      points += value;
      rules.add(code);
      explanations.add(explanation);
    }

    switch (reason) {
      case AbandonmentReason.ranOutOfTime:
        reward(4, 'shorter', 'Es más corta que la misión que dejaste');
      case AbandonmentReason.tooExpensive:
        reward(4, 'cheaper', 'Cuesta menos que la misión que dejaste');
      case AbandonmentReason.tooFar:
        if (noTravel) {
          reward(5, 'no_travel', 'No necesitas desplazarte');
        } else {
          reward(3, 'shorter_gps_distance', 'Queda más cerca de ti');
        }
      case AbandonmentReason.placeUnavailable:
        reward(4, 'no_venue', 'Puedes hacerla sin ir a un lugar específico');
      case AbandonmentReason.tooDifficult:
        reward(4, 'easier', 'Es más fácil');
      case AbandonmentReason.weatherOrMoodChanged:
        if (tags.any(_calmTags.contains)) {
          reward(2, 'calmer', 'Un cambio de ritmo más tranquilo');
        }
      case AbandonmentReason.other:
        break;
    }

    switch (alternativesWeatherCondition(context)) {
      case 'rain' || 'storm' || 'snow':
        if (noTravel) {
          reward(4, 'wet_no_travel', 'No tienes que salir con este clima');
        } else if (indoor) {
          reward(4, 'wet_indoor', 'Es bajo techo, ideal con este clima');
        }
        if (outdoor && !indoor) {
          points -= 4;
          rules.add('wet_outdoor_penalty');
        }
      case 'clear':
        if (outdoor && !indoor) {
          reward(4, 'clear_outdoor', 'Es al aire libre y el clima acompaña');
        }
    }

    switch (context.timeOfDay) {
      case 'night':
        if (noTravel) {
          reward(4, 'late_local', 'Sirve para esta hora, sin desplazarte');
        } else if (indoor) {
          reward(4, 'late_local', 'Es bajo techo y sirve para esta hora');
        }
        if (outdoor && !indoor) {
          points -= 3;
          rules.add('late_outdoor_penalty');
        }
      case 'morning':
        if (tags.any(_morningTags.contains)) reward(2, 'morning', 'Ideal para empezar la mañana');
      case 'evening':
        if (tags.any(_eveningTags.contains)) reward(2, 'evening', 'Ideal para el final del día');
    }

    final category = quest.category.toLowerCase();
    final matchesInterest = preferences.interests.any((interest) {
      final wanted = interest.toLowerCase();
      return category == wanted || tags.contains(wanted);
    });
    if (matchesInterest) reward(2, 'interest', 'Coincide con tus intereses');
    if (quest.socialLevel == preferences.socialLevel) {
      points += 1;
      rules.add('social_preference');
    }
    if (_difficultyRank(quest.difficulty) <= _difficultyRank(preferences.preferredDifficulty)) {
      points += 1;
      rules.add('difficulty_preference');
    }
    if (_budget(quest) == 0) reward(1, 'free', 'Es gratis');
    explanations.add('Se ajusta a tu tiempo y presupuesto');

    return QuestAlternative(
      quest: quest,
      score: points,
      explanations: explanations.toSet().toList(),
      ruleCodes: rules,
    );
  }

  bool _isAnywhere(Quest quest) => quest.locationMode == 'anywhere';

  /// Kotlin's budgetAmount: whole currency units.
  int _budget(Quest quest) => quest.estimatedCost.round();

  int _difficultyRank(String difficulty) => switch (difficulty) {
    'easy' => 0,
    'hard' => 2,
    _ => 1,
  };

  double? _gpsDistance(Quest quest, AppContext context) {
    final latitude = quest.latitude;
    final longitude = quest.longitude;
    if (!context.hasLocation || latitude == null || longitude == null) return null;
    return haversineKm(context.latitude!, context.longitude!, latitude, longitude);
  }
}
