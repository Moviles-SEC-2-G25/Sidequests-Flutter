import 'package:flutter/material.dart';

import '../../core/app_theme.dart';

/// Visual building blocks mirrored from the Kotlin app's ui/Components.kt, so
/// every screen draws its pills, chips, cards and stats the same way. These
/// are presentation only: callers keep their own state and callbacks.

/// Kotlin `MetaPill`: a small rounded label (11 sp, semi-bold).
class SqMetaPill extends StatelessWidget {
  final String text;

  /// Defaults to surfaceVariant, like Kotlin.
  final Color? color;
  final Color? textColor;

  const SqMetaPill(this.text, {super.key, this.color, this.textColor});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color ?? scheme.primaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: textColor ?? scheme.onSurface),
      ),
    );
  }
}

/// The uppercase micro-headings Kotlin uses all over ("I HAVE...", "THEME",
/// "SMART PICKS FOR YOU"): 10–11 sp, black weight, faded or accent-colored.
class SqSectionLabel extends StatelessWidget {
  final String text;
  final Color? color;
  final double fontSize;
  final double letterSpacing;

  const SqSectionLabel(
    this.text, {
    super.key,
    this.color,
    this.fontSize = 10,
    this.letterSpacing = 0,
  });

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: fontSize,
        fontWeight: FontWeight.w900,
        letterSpacing: letterSpacing,
        color: color ?? Theme.of(context).colorScheme.onSurface.withValues(alpha: .5),
      ),
    );
  }
}

/// Kotlin `ChoiceChip`, as a Material [ChoiceChip] (the theme gives it the
/// pill/border look) whose selected text follows the accent's luminance.
class SqChoiceChip extends StatelessWidget {
  final String label;
  final bool selected;
  final ValueChanged<bool>? onSelected;

  /// Kotlin's `selectedColor`; the theme's primary when null.
  final Color? selectedColor;

  const SqChoiceChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onSelected,
    this.selectedColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = selectedColor ?? theme.colorScheme.primary;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: onSelected,
      selectedColor: accent,
      labelStyle: theme.textTheme.labelLarge?.copyWith(
        color: selected ? AppColors.onAccent(accent) : theme.colorScheme.onSurface,
      ),
    );
  }
}

/// Kotlin's bordered surface card (`Card` with surface color and a 1 dp
/// outline border), the base of QuestCard, QuestFact and most panels.
class SqOutlinedCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final VoidCallback? onTap;
  final Color? color;
  final Color? borderColor;

  const SqOutlinedCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = 20,
    this.onTap,
    this.color,
    this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
      side: BorderSide(color: borderColor ?? scheme.outline),
    );
    return Material(
      color: color ?? scheme.surface,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// Kotlin's tinted, borderless card (e.g. `containerColor = Teal.copy(.14f)`).
class SqTintCard extends StatelessWidget {
  final Widget child;
  final Color color;
  final EdgeInsetsGeometry padding;
  final double radius;
  final VoidCallback? onTap;

  const SqTintCard({
    super.key,
    required this.child,
    required this.color,
    this.padding = const EdgeInsets.all(16),
    this.radius = 20,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(radius),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// Kotlin `QuestCard`: emoji tile, tag pills, title + category, two-line
/// description, an optional completion pill, the ⏱ 💰 📍 pills and, when the
/// caller passes them, its action buttons (right-aligned).
class SqQuestCard extends StatelessWidget {
  final String emoji;
  final String title;
  final String category;
  final String description;
  final List<Widget> tags;
  final Widget? completion;
  final List<String> meta;
  final List<Widget> actions;
  final VoidCallback? onTap;

  const SqQuestCard({
    super.key,
    required this.emoji,
    required this.title,
    required this.category,
    required this.description,
    this.tags = const [],
    this.completion,
    this.meta = const [],
    this.actions = const [],
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SqOutlinedCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 54,
                height: 54,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Text(emoji, style: const TextStyle(fontSize: 29)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (tags.isNotEmpty) ...[
                      Wrap(spacing: 6, runSpacing: 4, children: tags),
                      const SizedBox(height: 5),
                    ],
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium,
                    ),
                    Text(category, style: theme.textTheme.bodyMedium?.copyWith(color: scheme.secondary)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            description,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurface.withValues(alpha: .75)),
          ),
          if (completion != null) ...[const SizedBox(height: 10), completion!],
          if (meta.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(spacing: 7, runSpacing: 4, children: [for (final item in meta) SqMetaPill(item)]),
          ],
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 10),
            OverflowBar(
              alignment: MainAxisAlignment.end,
              spacing: 8,
              overflowSpacing: 4,
              overflowAlignment: OverflowBarAlignment.end,
              children: actions,
            ),
          ],
        ],
      ),
    );
  }
}

/// Kotlin's compact action button (Material `Button`): a 40 dp pill.
ButtonStyle sqPillButtonStyle({Color? background}) => FilledButton.styleFrom(
  minimumSize: const Size(0, 40),
  padding: const EdgeInsets.symmetric(horizontal: 24),
  shape: const StadiumBorder(),
  backgroundColor: background,
  foregroundColor: background == null ? null : AppColors.onAccent(background),
);

/// Kotlin's PrimaryButton with another container color (teal, error…).
ButtonStyle sqPrimaryButtonStyle(Color background) => FilledButton.styleFrom(
  backgroundColor: background,
  foregroundColor: AppColors.onAccent(background),
);

/// Kotlin `AccentStat`: emoji, value (extra-bold, accent) and a small label
/// on an accent-tinted card.
class SqAccentStat extends StatelessWidget {
  final String label;
  final String value;
  final String emoji;
  final Color color;

  const SqAccentStat({
    super.key,
    required this.label,
    required this.value,
    required this.emoji,
    this.color = AppColors.secondary,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .13),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(emoji, style: const TextStyle(fontSize: 21)),
          Text(value, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: color)),
          Text(
            label,
            style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .65)),
          ),
        ],
      ),
    );
  }
}

/// Kotlin's circular icon button (dark-mode toggle, back arrow): a
/// surfaceVariant circle with an emoji or glyph, 48 dp so it's easy to hit.
class SqCircleButton extends StatelessWidget {
  final String glyph;
  final VoidCallback? onTap;
  final double fontSize;
  final String? tooltip;

  const SqCircleButton({super.key, required this.glyph, this.onTap, this.fontSize = 18, this.tooltip});

  @override
  Widget build(BuildContext context) {
    final button = Material(
      color: Theme.of(context).colorScheme.primaryContainer,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: 48,
          height: 48,
          child: Center(child: Text(glyph, style: TextStyle(fontSize: fontSize))),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

/// Kotlin's secondary-screen header: a text "Back" (or "←") button followed
/// by the title, in a 12 dp padded row — used instead of an app bar.
class SqBackHeader extends StatelessWidget {
  final String title;
  final VoidCallback? onBack;

  /// "Back" by default; Kotlin's Mission History uses a 24 sp "←".
  final String backLabel;
  final TextStyle? titleStyle;
  final Widget? trailing;

  const SqBackHeader({
    super.key,
    required this.title,
    required this.onBack,
    this.backLabel = 'Back',
    this.titleStyle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          TextButton(
            onPressed: onBack,
            child: Text(backLabel, style: backLabel == '←' ? const TextStyle(fontSize: 24) : null),
          ),
          Expanded(
            child: Text(title, style: titleStyle ?? Theme.of(context).textTheme.headlineSmall),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Kotlin's rounded LinearProgressIndicator (pill track, custom colors).
class SqProgressBar extends StatelessWidget {
  final double value;
  final double height;
  final Color color;
  final Color? trackColor;

  const SqProgressBar({
    super.key,
    required this.value,
    this.height = 8,
    this.color = AppColors.secondary,
    this.trackColor,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: LinearProgressIndicator(
        value: value.isNaN ? 0 : value.clamp(0.0, 1.0),
        minHeight: height,
        color: color,
        backgroundColor: trackColor ?? Theme.of(context).colorScheme.primaryContainer,
      ),
    );
  }
}

/// The five bottom-bar glyphs of the Kotlin app (res/drawable/ic_*.xml),
/// drawn as the same 24×24 outline paths with a 1.8 stroke.
enum SqNavGlyph { explore, nearby, social, quest, profile }

class SqNavIcon extends StatelessWidget {
  final SqNavGlyph glyph;

  const SqNavIcon(this.glyph, {super.key});

  @override
  Widget build(BuildContext context) {
    final iconTheme = IconTheme.of(context);
    final size = iconTheme.size ?? 24;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _NavGlyphPainter(glyph, iconTheme.color ?? Colors.black)),
    );
  }
}

class _NavGlyphPainter extends CustomPainter {
  final SqNavGlyph glyph;
  final Color color;

  _NavGlyphPainter(this.glyph, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24, size.height / 24);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = glyph == SqNavGlyph.social ? StrokeCap.round : StrokeCap.butt;
    canvas.drawPath(_path(), paint);
  }

  Path _path() {
    switch (glyph) {
      case SqNavGlyph.explore:
        return Path()
          ..addOval(Rect.fromCircle(center: const Offset(12, 12), radius: 9))
          ..moveTo(16, 8)
          ..lineTo(13.6, 13.6)
          ..lineTo(8, 16)
          ..lineTo(10.4, 10.4)
          ..close();
      case SqNavGlyph.nearby:
        return Path()
          ..moveTo(12, 21)
          ..cubicTo(7.5, 17, 5, 13.8, 5, 10)
          ..arcToPoint(const Offset(19, 10), radius: const Radius.circular(7))
          ..cubicTo(19, 13.8, 16.5, 17, 12, 21)
          ..close()
          ..addOval(Rect.fromCircle(center: const Offset(12, 10), radius: 2.4));
      case SqNavGlyph.social:
        return Path()
          ..addOval(Rect.fromCircle(center: const Offset(9, 7.5), radius: 3))
          ..moveTo(2.5, 19)
          ..lineTo(2.5, 17.4)
          ..cubicTo(2.5, 14.9, 5.7, 13.2, 9, 13.2)
          ..cubicTo(12.3, 13.2, 15.5, 14.9, 15.5, 17.4)
          ..lineTo(15.5, 19)
          ..close()
          ..moveTo(16, 5)
          ..cubicTo(19.6, 5, 19.6, 10, 16, 10)
          ..moveTo(18, 13.6)
          ..cubicTo(20.5, 14.2, 21.5, 15.7, 21.5, 17.3)
          ..lineTo(21.5, 19);
      case SqNavGlyph.quest:
        return Path()
          ..moveTo(13, 3)
          ..lineTo(5.5, 13)
          ..lineTo(11, 13)
          ..lineTo(10.5, 21)
          ..lineTo(18.5, 10.5)
          ..lineTo(13.2, 10.5)
          ..close();
      case SqNavGlyph.profile:
        return Path()
          ..addOval(Rect.fromCircle(center: const Offset(12, 7.5), radius: 3.5))
          ..moveTo(5, 20)
          ..lineTo(5, 17.7)
          ..cubicTo(5, 15.3, 8.3, 13.8, 12, 13.8)
          ..cubicTo(15.7, 13.8, 19, 15.3, 19, 17.7)
          ..lineTo(19, 20)
          ..close();
    }
  }

  @override
  bool shouldRepaint(_NavGlyphPainter oldDelegate) => oldDelegate.glyph != glyph || oldDelegate.color != color;
}
