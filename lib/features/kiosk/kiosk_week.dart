/// „Hráči týdne“ on the kiosk (the panels' module `week`, 0078): the best
/// results of the alley's own players in the previous Monday–Sunday. The
/// card shows as many categories as fit, each with its best three, and a
/// tap anywhere on it opens the whole week full screen
/// ([showKioskWeekPlayers]): every player of ours, home, away or both,
/// ranked by category, competition or club — a tap on a line opens that
/// match's Zápis. Display only, like the rest of the panels; the rankings
/// themselves are pure (week_players.dart).
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/clock.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';
import '../../domain/palette.dart';
import '../../domain/week_players.dart';
import 'kiosk_info_panel.dart' show KioskCard;

const _blockTitleStyle = TextStyle(fontSize: 15, fontWeight: FontWeight.w800);
const _entryStyle = TextStyle(fontSize: 17, fontWeight: FontWeight.w700);
const _entryTeamStyle = TextStyle(fontSize: 13);
const _titleGap = 4.0;
const _entryGap = 6.0;
const _blockGap = 14.0;

/// The „Více“ line under the blocks that fit (as Nástěnka's).
const _footerHeight = 32.0;

/// How many players of a category the card lists.
const _cardTop = 3;

/// The week's Monday by the app clock: what the title names — the same one
/// [weekPlayersProvider] reads, flipping with it at Monday 00:00.
Day _monday(WidgetRef ref) => ref.watch(
  nowProvider.select((now) => previousWeekMonday(now.value ?? DateTime.now())),
);

/// „doma“ / „venku“: the alley's home or away, as on the board.
String _where(WeekLine line) => line.isAway ? 'venku' : 'doma';

/// What the card stacks: the categories, ranked — or, while no line has a
/// known gender and number of throws yet (the register still being asked),
/// the competitions, so the card is never empty with lines in the week.
List<({String title, List<WeekLine> lines})> _cardBlocks(
  List<WeekLine> lines,
) {
  final categories = weekCategories(lines);
  if (categories.isNotEmpty) {
    return [
      for (final MapEntry(key: category, value: ranked) in categories.entries)
        (title: category.label, lines: ranked),
    ];
  }
  return [
    for (final group in weekByCompetition(lines))
      (title: group.name, lines: group.lines),
  ];
}

/// The card: „HRÁČI TÝDNE · 5.–11. 10.“, then the categories that fit
/// whole, each its best three — „1. Jan Novák 598“ and, smaller, „Termínátor
/// A · doma“ — and „Více“ when some were left out (the first one is shown
/// even when cut). A tap anywhere opens the whole week ([onOpen]). The
/// panel shows it only while the week has lines.
class KioskWeekCard extends ConsumerWidget {
  const KioskWeekCard({super.key, required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final lines = ref.watch(weekPlayersProvider).value ?? const <WeekLine>[];
    final blocks = _cardBlocks(lines);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onOpen,
      child: KioskCard(
        icon: Icons.emoji_events_outlined,
        title: 'HRÁČI TÝDNE · ${weekRangeLabel(_monday(ref))}',
        fill: true,
        child: LayoutBuilder(
          builder: (context, box) {
            final fit = _fit(context, box, blocks);
            final shown = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (i, block) in blocks.take(fit.count).indexed) ...[
                  if (i > 0) const SizedBox(height: _blockGap),
                  _CardBlock(title: block.title, ranked: block.lines),
                ],
              ],
            );
            if (!fit.cut) {
              return Align(alignment: Alignment.topLeft, child: shown);
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: ClipRect(
                    child: SingleChildScrollView(
                      physics: const NeverScrollableScrollPhysics(),
                      child: shown,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: _footerHeight - 8,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Text(
                        'Více',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: scheme.primary,
                        ),
                      ),
                      Icon(Icons.expand_more, size: 20, color: scheme.primary),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// How many of [blocks] the card's interior [box] shows, and whether
  /// some are left out (or the only one shown is cut). Measured with the
  /// styles the lines are drawn in, merged into the ambient one, at the
  /// visitor's text size; every line is one line high (ellipsized).
  ({int count, bool cut}) _fit(
    BuildContext context,
    BoxConstraints box,
    List<({String title, List<WeekLine> lines})> blocks,
  ) {
    if (blocks.isEmpty) return (count: 0, cut: false);
    final base = DefaultTextStyle.of(context).style;
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    double line(TextStyle style) {
      final painter = TextPainter(
        text: TextSpan(text: 'Ág', style: base.merge(style)),
        textDirection: direction,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final h = painter.height;
      painter.dispose();
      return h;
    }

    final title = line(_blockTitleStyle);
    final entry = line(_entryStyle) + line(_entryTeamStyle);
    double height(int players) {
      final n = math.min(players, _cardTop);
      return title + _titleGap + n * entry + (n - 1) * _entryGap;
    }

    final room = box.hasBoundedHeight ? box.maxHeight : double.infinity;
    var total = 0.0;
    for (final (i, block) in blocks.indexed) {
      total += (i > 0 ? _blockGap : 0) + height(block.lines.length);
    }
    if (total <= room) return (count: blocks.length, cut: false);
    // Not all of them: „Více“ takes its line, the blocks that fit whole
    // above it stay — at least the first one, cut.
    final left = room - _footerHeight;
    var used = 0.0;
    var count = 0;
    for (final block in blocks) {
      final next = (count > 0 ? _blockGap : 0) + height(block.lines.length);
      if (used + next > left) break;
      used += next;
      count++;
    }
    return (count: math.max(count, 1), cut: true);
  }
}

/// One category of the card: its label and its best three.
class _CardBlock extends StatelessWidget {
  const _CardBlock({required this.title, required this.ranked});

  final String title;
  final List<WeekLine> ranked;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final places = weekPlaces(ranked);
    final shown = ranked.take(_cardTop).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: _blockTitleStyle.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: _titleGap),
        for (final (i, line) in shown.indexed) ...[
          if (i > 0) const SizedBox(height: _entryGap),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${places[i]}. ${line.playerName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _entryStyle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${line.total}',
                maxLines: 1,
                style: _entryStyle.copyWith(fontWeight: FontWeight.w800),
              ),
            ],
          ),
          Text(
            '${line.teamName} · ${_where(line)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: _entryTeamStyle.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }
}

/// Opens „Hráči týdne“ full screen over the kiosk, fading in like the
/// Zápis. [wrap] is the shell's: the kiosk's theme, and a touch counts for
/// the idle timer — whose reset closes it, with every other route.
/// [onOpenMatch] opens a match's Zápis (over this page).
Future<void> showKioskWeekPlayers(
  BuildContext context, {
  required Widget Function(Widget child) wrap,
  required void Function(PrioritySlot match) onOpenMatch,
}) => showGeneralDialog<void>(
  context: context,
  barrierColor: Colors.black54,
  transitionDuration: const Duration(milliseconds: 250),
  transitionBuilder: (context, animation, _, child) => FadeTransition(
    opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
    child: child,
  ),
  pageBuilder: (context, _, _) =>
      wrap(KioskWeekPlayersPage(onOpenMatch: onOpenMatch)),
);

/// The detail's three ways to group the week.
enum _WeekView { categories, competitions, clubs }

/// One column of the detail: a full ranking, with the club's palette
/// colour in the club view.
typedef _Group = ({String title, int? color, List<WeekLine> lines});

/// The whole week: „Hráči týdne 5.–11. 10.“, chips Vše / Doma / Venku,
/// segments Kategorie / Soutěže / Oddíly, and one column per group — side
/// by side, scrolling sideways when they do not fit. Each column a full
/// ranking: the place, the name, the result, and smaller the team, the
/// opponent and home or away. A tap on a line opens that match's Zápis.
class KioskWeekPlayersPage extends ConsumerStatefulWidget {
  const KioskWeekPlayersPage({super.key, required this.onOpenMatch});

  final void Function(PrioritySlot match) onOpenMatch;

  @override
  ConsumerState<KioskWeekPlayersPage> createState() =>
      _KioskWeekPlayersPageState();
}

class _KioskWeekPlayersPageState extends ConsumerState<KioskWeekPlayersPage> {
  /// Home (false), away (true) or all (null).
  bool? _away;
  _WeekView _view = _WeekView.categories;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final lines = weekWhere(
      ref.watch(weekPlayersProvider).value ?? const <WeekLine>[],
      away: _away,
    );
    final slots = {for (final s in ref.watch(prioritySlotsProvider)) s.id: s};
    final List<_Group> groups = switch (_view) {
      _WeekView.categories => [
        for (final MapEntry(key: category, value: ranked)
            in weekCategories(lines).entries)
          (title: category.label, color: null, lines: ranked),
      ],
      _WeekView.competitions => [
        for (final g in weekByCompetition(lines))
          (title: g.name, color: null, lines: g.lines),
      ],
      _WeekView.clubs => [
        for (final g in weekByClub(lines))
          (title: g.name, color: g.color, lines: g.lines),
      ],
    };
    // A line whose match the slots do not hold (yet) opens nothing.
    VoidCallback? open(WeekLine line) => switch (slots[line.matchId]) {
      final slot? => () => widget.onOpenMatch(slot),
      null => null,
    };
    return Material(
      color: scheme.surfaceContainerLowest,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Hráči týdne ${weekRangeLabel(_monday(ref))}',
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    iconSize: 32,
                    tooltip: 'Zavřít',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (final (label, away) in const [
                    ('Vše', null),
                    ('Doma', false),
                    ('Venku', true),
                  ])
                    ChoiceChip(
                      label: Text(label),
                      selected: _away == away,
                      onSelected: (_) => setState(() => _away = away),
                    ),
                  const SizedBox(width: 16),
                  SegmentedButton<_WeekView>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(
                        value: _WeekView.categories,
                        label: Text('Kategorie'),
                      ),
                      ButtonSegment(
                        value: _WeekView.competitions,
                        label: Text('Soutěže'),
                      ),
                      ButtonSegment(
                        value: _WeekView.clubs,
                        label: Text('Oddíly'),
                      ),
                    ],
                    selected: {_view},
                    onSelectionChanged: (chosen) =>
                        setState(() => _view = chosen.first),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Expanded(
                child: groups.isEmpty
                    ? Center(
                        child: Text(
                          'Žádné výsledky pro tento výběr.',
                          style: TextStyle(
                            fontSize: 16,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    : _Columns(groups: groups, open: open),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The groups side by side, sharing the width — or, when they would be
/// narrower than [minWidth], each [minWidth] wide in a row that scrolls
/// sideways.
class _Columns extends StatelessWidget {
  const _Columns({required this.groups, required this.open});

  static const minWidth = 320.0;
  static const gap = 16.0;

  final List<_Group> groups;
  final VoidCallback? Function(WeekLine line) open;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final fits =
          groups.length * minWidth + (groups.length - 1) * gap <=
          box.maxWidth;
      if (fits) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (i, group) in groups.indexed) ...[
              if (i > 0) const SizedBox(width: gap),
              Expanded(
                child: _GroupColumn(group: group, open: open),
              ),
            ],
          ],
        );
      }
      return ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: groups.length,
        separatorBuilder: (_, _) => const SizedBox(width: gap),
        itemBuilder: (context, i) => SizedBox(
          width: minWidth,
          child: _GroupColumn(group: groups[i], open: open),
        ),
      );
    },
  );
}

/// One group's full ranking, under its name (and the club's colour).
class _GroupColumn extends StatelessWidget {
  const _GroupColumn({required this.group, required this.open});

  final _Group group;
  final VoidCallback? Function(WeekLine line) open;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ranked = group.lines;
    final places = weekPlaces(ranked);
    final club = group.color == null
        ? null
        : ClubColors.of(group.color!, scheme.brightness);
    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 14, 10, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                children: [
                  if (club != null) ...[
                    Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        color: club.$1,
                        shape: BoxShape.circle,
                        border: Border.all(color: club.$2),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Text(
                      group.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: scheme.primary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: ranked.length,
                itemBuilder: (context, i) => _DetailRow(
                  place: places[i],
                  line: ranked[i],
                  onTap: open(ranked[i]),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One player in a column: the place, the name and the result, and under
/// them, smaller, the team, the opponent and home or away.
class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.place,
    required this.line,
    required this.onTap,
  });

  static const placeWidth = 36.0;

  final int place;
  final WeekLine line;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                SizedBox(
                  width: placeWidth,
                  child: Text(
                    '$place.',
                    style: _entryStyle.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    line.playerName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _entryStyle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${line.total}',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: placeWidth),
              child: Text(
                '${line.teamName} – ${line.opponent} · ${_where(line)}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: _entryTeamStyle.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
