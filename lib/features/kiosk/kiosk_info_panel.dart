/// The kiosk's two side panels (0077), left and right of the board, each a
/// stack of the modules the admin placed in it: who serves on the canteen
/// and who comes next (0073), the alley's active notices (they take turns
/// when there are several; a tap reads one in full), the matches of the
/// last and next weeks (a tap on a finished one opens its Zápis, ▶ at one
/// with a video its stream) — and, while a match is being played, that
/// match across the whole panel holding the matches, in the Souboje view
/// (several live matches take turns too). Display only, like the board:
/// nothing here books or writes. Closed a panel is gone entirely, leaving
/// only a button floating over the board. The admin picks what goes where
/// and how it looks (Správa → Kiosk); the shell closes or reopens both
/// panels to their resting state after a minute without a touch.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../core/widgets/emoji_text.dart';
import '../../data/clock.dart';
import '../../data/providers.dart';
import '../../domain/duels.dart';
import '../../domain/duties.dart' show KioskDutyEntry;
import '../../domain/kiosk_layout.dart';
import '../../domain/kiosk_panel.dart';
import '../../domain/models.dart';
import '../../domain/palette.dart';
import '../../domain/results.dart';
import '../clubhouse/widgets/duel_card.dart';
import '../clubhouse/widgets/duels_compact.dart';
import '../clubhouse/widgets/match_scoreboard.dart';
import '../clubhouse/widgets/match_title.dart';
import '../clubhouse/widgets/match_video_icon.dart';
import '../clubhouse/widgets/team_totals_card.dart';
import 'kiosk_duty.dart' show kioskDutyPlanProvider;
import 'kiosk_feedback.dart' show KioskFeedbackCard;
import 'kiosk_guide.dart' show KioskGuideCard;
import 'kiosk_week.dart' show KioskWeekCard;

const _resultRowHeight = 64.0;
const _moreRowHeight = 52.0;

/// Asks the server for a fresh score of the match [id] (refresh_match,
/// forced: the kiosk's own clock decides how often) and hands back its
/// answer — `queued` (a fetch is on its way), `fresh` or `not_live`
/// (nothing will come). Errors are swallowed into null — a failed ask
/// leaves the score as it was, and the age line says how old.
final kioskRefreshMatchProvider =
    Provider<Future<String?> Function(String id)>(
  (ref) => (id) async {
    try {
      return await Api.refreshMatch(id, force: true);
    } catch (e) {
      debugPrint('Kiosk: refresh of $id failed: $e');
      return null;
    }
  },
);

/// The longest the ⟳ of the live view turns for one ask: a fetch the
/// server queued lands well within it; one that does not is given up on.
const kioskRefreshWait = Duration(seconds: 30);

/// The shortest it turns: an answer that comes at once (`fresh`) would
/// otherwise stop it before it ever started, and a tap would show nothing.
const kioskRefreshMinSpin = Duration(milliseconds: 800);

/// The matches being played whose players the site has delivered — empty
/// with live mode off, or while the matches are in no panel (0077): the
/// match being played takes over the panel that holds them. A match marked
/// as playing but without data is not here ([kioskLiveMatches]).
final kioskLiveProvider = Provider<List<PrioritySlot>>((ref) {
  final settings = ref.watch(settingsProvider).value;
  final panels = settings?.kioskPanels ?? KioskPanels.defaults;
  if (panels.sideOf(KioskModule.matches) == PanelSide.off ||
      !(settings?.kioskLiveMode ?? true)) {
    return const [];
  }
  final slots = ref.watch(prioritySlotsProvider);
  final results = ref.watch(matchResultsProvider).value ?? const {};
  final withData = <String>{};
  for (final s in slots) {
    if (results[s.id]?.status != MatchStatus.inProgress) continue;
    if (ref.watch(matchPlayerResultsProvider(s.id)).value?.isNotEmpty ??
        false) {
      withData.add(s.id);
    }
  }
  return kioskLiveMatches(
    slots: slots,
    results: results,
    withData: withData,
    now: ref.watch(nowProvider).value ?? DateTime.now(),
  );
});

/// What the panel on [side] would show now, from the providers and the
/// admin's layout (0077): the modules placed there that have something to
/// show, in the admin's order, each with its share — null when none has
/// (the shell then draws neither that panel nor its button).
final kioskPanelContentProvider =
    Provider.family<KioskPanelContent?, PanelSide>((ref, side) {
      final settings = ref.watch(settingsProvider).value;
      final placed = (settings?.kioskPanels ?? KioskPanels.defaults)
          .modulesOn(side);
      if (placed.isEmpty) return null;
      bool here(KioskModule module) => placed.any((p) => p.module == module);
      final now = ref.watch(nowProvider).value ?? DateTime.now();
      final live = here(KioskModule.matches)
          ? ref.watch(kioskLiveProvider)
          : const <PrioritySlot>[];
      final notices = here(KioskModule.notices)
          ? kioskNotices(ref.watch(messagesProvider).value ?? const [], now)
          : const <Message>[];
      final hasMatches =
          here(KioskModule.matches) &&
          kioskMatchWindow(
            slots: ref.watch(prioritySlotsProvider),
            today: Day.fromDateTime(now),
            weeksBack: settings?.kioskWeeksBack ?? 2,
            weeksAhead: settings?.kioskWeeksAhead ?? 1,
            showUpcoming: settings?.kioskShowUpcoming ?? true,
          ).matches.isNotEmpty;
      // The canteen duty's plan (0073) is read only with its card here. A
      // plan with nobody now and nobody ahead has nothing to say.
      final plan = here(KioskModule.duty)
          ? ref.watch(kioskDutyPlanProvider)
          : null;
      final duty = plan != null && (plan.now != null || plan.next.isNotEmpty)
          ? plan
          : null;
      // The previous week's lines of ours (0078) are read only with their
      // card here; a week without a line has nothing to rank.
      final hasWeek =
          here(KioskModule.week) &&
          (ref.watch(weekPlayersProvider).value?.lines.isNotEmpty ?? false);
      final entries = <KioskPanelEntry>[];
      for (final placement in placed) {
        final module = placement.module!;
        final shows = switch (module) {
          KioskModule.duty => duty != null,
          KioskModule.notices => notices.isNotEmpty,
          // The list — or the match being played alone, when the list's
          // weeks hold no match (Sunday evening's, still live on Monday).
          KioskModule.matches => hasMatches || live.isNotEmpty,
          // Fixed texts: always something to show.
          KioskModule.guide || KioskModule.feedback => true,
          KioskModule.week => hasWeek,
        };
        if (shows) entries.add(KioskPanelEntry(module, placement.share));
      }
      if (entries.isEmpty) return null;
      return KioskPanelContent(
        side: side,
        entries: entries,
        notices: notices,
        hasMatches: hasMatches,
        live: live,
        duty: duty,
      );
    });

/// What one panel shows (0077): [entries] are its modules with something
/// to show, top to bottom; the rest is what those modules draw.
class KioskPanelContent {
  const KioskPanelContent({
    required this.side,
    required this.entries,
    this.notices = const [],
    this.hasMatches = false,
    this.live = const [],
    this.duty,
  });

  final PanelSide side;
  final List<KioskPanelEntry> entries;
  final List<Message> notices;

  /// The list of matches has a match in its weeks.
  final bool hasMatches;

  /// Matches being played, with data; non-empty = the panel holding the
  /// matches shows only them. Empty in the other panel.
  final List<PrioritySlot> live;

  /// The canteen duty's plan for its card (0073); null with the card in
  /// another panel or nothing planned.
  final ({KioskDutyEntry? now, List<KioskDutyEntry> next})? duty;
}

/// One module of a panel and its share of the panel's height, in percent
/// (5–95). The shares of a panel are weights: they need not add up to 100.
class KioskPanelEntry {
  const KioskPanelEntry(this.module, this.share);

  final KioskModule module;
  final int share;
}

/// One side panel: its modules stacked top to bottom, each its share of
/// the height with 12 px between them — or, while a match is being played,
/// that match alone in the panel holding the matches.
class KioskPanelView extends ConsumerWidget {
  const KioskPanelView({
    super.key,
    required this.side,
    required this.width,
    required this.content,
    required this.open,
    this.hidden = false,
    required this.onOpenNotice,
    required this.onOpenMatch,
    this.onOpenGuide,
    this.onOpenWeek,
    this.onOpenFeedback,
    this.onPlay,
    this.resetToken = 0,
    this.boardDays,
    this.showLive = true,
    this.onShowLive,
  });

  /// Left or right of the board: the panel grows from that edge of the
  /// screen.
  final PanelSide side;

  /// Open, it is this wide: whole day columns of the board
  /// ([kioskPanelWidths], worked out once by the shell for both panels).
  final double width;

  /// False after a visitor switched from the match being played to the
  /// list of matches; the idle reset turns it back.
  final bool showLive;

  /// Between the live view and the list: true = the live match. Null in
  /// the panel without the matches.
  final void Function(bool live)? onShowLive;

  /// Bumped by the shell on every idle reset: the cards that scroll or page
  /// start over.
  final int resetToken;

  /// The days a visitor scrolled the board to, when the list follows it.
  final ({Day first, Day last})? boardDays;

  final KioskPanelContent content;
  final bool open;

  /// Out of the way while a visitor books: shut like a closed panel, yet
  /// an [open] one keeps its contents built behind the scenes — the match
  /// being played keeps asking for its score, its pin and its turn, and is
  /// there as it was once the pick is cleared.
  final bool hidden;
  final void Function(Message notice) onOpenNotice;
  final void Function(PrioritySlot match) onOpenMatch;

  /// A tap on „Jak začít“: the whole guide with the large QR code; null =
  /// a tap does nothing.
  final VoidCallback? onOpenGuide;

  /// A tap on „Hráči týdne“: the whole week full screen; null = a tap does
  /// nothing.
  final VoidCallback? onOpenWeek;

  /// A tap on „Napište nám“: its QR code large; null = a tap does nothing.
  final VoidCallback? onOpenFeedback;

  /// ▶ at a match with a video: its stream (0072); null while the admin
  /// has the streams off — no ▶ and no live badge.
  final void Function(PrioritySlot match)? onPlay;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final settings = ref.watch(settingsProvider).value;
    final noticeTurn = Duration(
      seconds: settings?.kioskNoticesRotationSeconds ?? 12,
    );
    final liveTurn = Duration(
      seconds: settings?.kioskLiveRotationSeconds ?? 12,
    );
    final entries = content.entries;
    // The notices alone keep their natural height: one short notice is not
    // stretched over the whole panel. With other modules each takes its
    // share.
    final noticesAlone =
        entries.length == 1 && entries.single.module == KioskModule.notices;
    Widget card(KioskModule module) => switch (module) {
      // A new key after every idle reset: scrolled down, the plan starts
      // over at the top.
      KioskModule.duty => _DutyCard(
        key: ValueKey(resetToken),
        plan: content.duty!,
      ),
      KioskModule.notices => _NoticesCard(
        notices: content.notices,
        turn: noticeTurn,
        fill: !noticesAlone,
        onOpen: onOpenNotice,
      ),
      // A new key after every idle reset: the list starts over (its weeks
      // and its scroll) like the rest of the kiosk.
      KioskModule.matches => _MatchesCard(
        key: ValueKey(resetToken),
        onOpen: onOpenMatch,
        onPlay: onPlay,
        boardDays: boardDays,
        // Back to the match being played, when one is.
        onShowLive: content.live.isEmpty || onShowLive == null
            ? null
            : () => onShowLive!(true),
      ),
      KioskModule.guide => KioskGuideCard(onOpen: () => onOpenGuide?.call()),
      // A new key after every idle reset, as the other cards of the
      // panel: the card starts over.
      KioskModule.week => KioskWeekCard(
        key: ValueKey(resetToken),
        onOpen: () => onOpenWeek?.call(),
      ),
      KioskModule.feedback => KioskFeedbackCard(
        onOpen: () => onOpenFeedback?.call(),
      ),
    };
    final showsLive =
        content.live.isNotEmpty && (showLive || !content.hasMatches);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      width: open && !hidden ? width : 0,
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(color: scheme.surfaceContainer),
      // Laid out at its full width even while it grows or shrinks, so the
      // text does not reflow during the animation — from its inner edge,
      // the one beside the board: the left panel slides out of the
      // screen's left edge as the right one out of its right edge.
      child: OverflowBox(
        alignment: side == PanelSide.left
            ? Alignment.centerRight
            : Alignment.centerLeft,
        minWidth: width,
        maxWidth: width,
        child: !open
            ? const SizedBox.shrink()
            : Offstage(
                offstage: hidden,
                child: showsLive
                    ? _LiveView(
                        matches: content.live,
                        turn: liveTurn,
                        onOpenMatch: onOpenMatch,
                        onPlay: onPlay,
                        onShowList: !content.hasMatches || onShowLive == null
                            ? null
                            : () => onShowLive!(false),
                      )
                    : Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // Keyed by the module: a module coming or
                            // going (a notice expiring) leaves the others
                            // their state.
                            for (final (i, entry) in entries.indexed) ...[
                              if (i > 0) const SizedBox(height: 12),
                              if (noticesAlone)
                                Flexible(
                                  key: ValueKey(entry.module),
                                  child: card(entry.module),
                                )
                              else
                                Expanded(
                                  key: ValueKey(entry.module),
                                  flex: entry.share,
                                  child: card(entry.module),
                                ),
                            ],
                          ],
                        ),
                      ),
              ),
      ),
    );
  }
}

/// The button that opens and closes a panel: a bare double arrow pointing
/// the way the panel moves, gray and half see-through, floating over the
/// board at the panel's inner edge (the right one at the board's right
/// edge, the left one on the hour ruler — never over today's column).
/// Every few seconds it breathes once — a soft glow and a little more
/// opacity — so a tablet on the wall shows that there is something to
/// open, without ever moving; both buttons breathe together.
class KioskDrawerButton extends StatelessWidget {
  const KioskDrawerButton({
    super.key,
    required this.side,
    required this.open,
    required this.onTap,
    this.breathe = true,
  }) : assert(side != PanelSide.off);

  /// The panel it opens and closes: left or right.
  final PanelSide side;
  final bool open;
  final VoidCallback onTap;

  /// Off = a still button (the admin's „Opakující se animace“, 0065):
  /// every breath repaints the screen, which a slow display feels.
  final bool breathe;

  static const size = 56.0;
  static const margin = 8.0;

  /// One breath, and the rest between two.
  static const pulse = Duration(milliseconds: 2400);
  static const pause = Duration(milliseconds: 1800);

  /// How long from [now] until the next breath. Every button breathes at
  /// the multiples of [pulse] + [pause] on the wall clock, whenever it
  /// appeared: the two panels' buttons breathe together, and the screen
  /// rests between — two breaths out of step would leave it hardly any
  /// frame without an animation.
  static Duration untilBreath(DateTime now) {
    final period = (pulse + pause).inMilliseconds;
    final into = now.millisecondsSinceEpoch % period;
    return Duration(milliseconds: into == 0 ? 0 : period - into);
  }

  /// The wall clock the breaths keep time by; a widget test hands in its
  /// fake one, which moves with the pumps.
  @visibleForTesting
  static DateTime Function() clock = DateTime.now;

  @override
  Widget build(BuildContext context) {
    final left = side == PanelSide.left;
    // The way a tap moves the panel: the right one opens to the left and
    // closes to the right, the left one the other way round.
    final towardsRight = left != open;
    return Semantics(
      // A node of its own: two buttons, each known by its label.
      container: true,
      button: true,
      label: '${open ? 'Skrýt' : 'Zobrazit'} ${left ? 'levý' : 'pravý'} panel',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Center(
            child: KioskBreathingIcon(
              towardsRight
                  ? Icons.keyboard_double_arrow_right
                  : Icons.keyboard_double_arrow_left,
              breathe: breathe,
            ),
          ),
        ),
      ),
    );
  }
}

/// An icon that breathes like [KioskDrawerButton]'s — once every few
/// seconds on the same wall-clock beat ([KioskDrawerButton.untilBreath]), a
/// soft glow and a little more opacity — or keeps still ([breathe] off).
/// The side panels' buttons and the Zápis's side arrows (0079) wear it, so
/// whatever on the wall opens or turns breathes together. [enabled] false
/// = a dim, still icon: nothing that way. [strong]: on a disc of its own
/// (over the Zápis), where the panel's faint grey would hardly show — the
/// disc's foreground, nearly whole, the breath on top.
class KioskBreathingIcon extends StatefulWidget {
  const KioskBreathingIcon(
    this.icon, {
    super.key,
    this.breathe = true,
    this.enabled = true,
    this.strong = false,
    this.size = 44,
  });

  final IconData icon;
  final bool breathe;
  final bool enabled;
  final bool strong;
  final double size;

  @override
  State<KioskBreathingIcon> createState() => _KioskBreathingIconState();
}

class _KioskBreathingIconState extends State<KioskBreathingIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: KioskDrawerButton.pulse,
  );
  Timer? _rest;

  bool get _breathes => widget.breathe && widget.enabled;

  @override
  void initState() {
    super.initState();
    if (_breathes) _breathe();
  }

  @override
  void didUpdateWidget(KioskBreathingIcon old) {
    super.didUpdateWidget(old);
    if ((old.breathe && old.enabled) == _breathes) return;
    if (_breathes) {
      _breathe();
    } else {
      // Mid-breath: stopped, and no rest timer follows a breath that never
      // finished (whenComplete waits for the finish).
      _rest?.cancel();
      _controller.stop();
      _controller.value = 0;
    }
  }

  /// A rest on a timer until the shared rhythm's next breath
  /// ([KioskDrawerButton.untilBreath]), then one breath, and again (not a
  /// repeating animation, which would keep a test's pumpAndSettle from ever
  /// settling).
  void _breathe() {
    _rest?.cancel();
    final wait = KioskDrawerButton.untilBreath(KioskDrawerButton.clock());
    _rest = Timer(wait, () {
      if (!mounted) return;
      _controller.forward(from: 0).whenComplete(() {
        if (mounted && _breathes) _breathe();
      });
    });
  }

  @override
  void dispose() {
    _rest?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Its own layer: a breath repaints the icon, not the board and the
    // panel under it.
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          // 0 → 1 → 0 over one breath; 0 while the icon is still.
          final glow = math.sin(_controller.value * math.pi);
          final (color, rest, breath, off) = widget.strong
              ? (scheme.onSurface, 0.75, 0.25, 0.25)
              : (scheme.onSurfaceVariant, 0.4, 0.35, 0.15);
          return Icon(
            widget.icon,
            size: widget.size,
            color: color.withValues(
              alpha: widget.enabled ? rest + breath * glow : off,
            ),
            shadows: [
              Shadow(
                color: scheme.primary.withValues(alpha: 0.75 * glow),
                blurRadius: 4 + 16 * glow,
              ),
            ],
          );
        },
      ),
    );
  }
}

/// A horizontal swipe over [child]: a fling to the left asks for the next
/// item ([onSwipe] 1), to the right for the previous one (-1). Vertical
/// scrolling inside [child] is untouched.
class _Swipe extends StatelessWidget {
  const _Swipe({required this.onSwipe, required this.child});

  final void Function(int direction) onSwipe;
  final Widget child;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.translucent,
    onHorizontalDragEnd: (details) {
      final v = details.primaryVelocity ?? 0;
      if (v.abs() < 200) return;
      onSwipe(v < 0 ? 1 : -1);
    },
    child: child,
  );
}

/// A rounded card with a title, the frame of every module of a panel
/// (public for the modules that live in files of their own); [fill] makes
/// its body take all the height the card is given (its slot of the
/// panel), otherwise it is as tall as its content.
class KioskCard extends StatelessWidget {
  const KioskCard({
    super.key,
    required this.icon,
    required this.title,
    required this.child,
    this.fill = false,
    this.action,
  });

  final IconData icon;
  final String title;
  final Widget child;
  final bool fill;

  /// At the right of the title row.
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: fill ? MainAxisSize.max : MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              // In a narrow drawer (one column of many days) a long title
              // wraps rather than running out of the card.
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.4,
                    color: scheme.primary,
                  ),
                ),
              ),
              ?action,
            ],
          ),
          const SizedBox(height: 10),
          fill ? Expanded(child: child) : Flexible(child: child),
        ],
      ),
    );
  }
}

/// The canteen duty (0073, „V panelu“): who serves now, large on the duty's
/// tint (the status bar's line and the board's band wear it too), or that
/// nobody does today — then the next ones in date order, each its range on
/// the left and its names on the right (under it in a narrow drawer). It
/// fills its slot of the drawer and scrolls when the slot is too short for
/// the plan.
class _DutyCard extends StatelessWidget {
  const _DutyCard({super.key, required this.plan});

  final ({KioskDutyEntry? now, List<KioskDutyEntry> next}) plan;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final now = plan.now;
    final muted = TextStyle(fontSize: 15, color: scheme.onSurfaceVariant);
    return KioskCard(
      icon: Icons.local_cafe_outlined,
      title: 'SLUŽBA NA KANTÝNĚ',
      fill: true,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (now == null)
              Text('Dnes nikdo neslouží.', style: muted)
            else
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Teď slouží',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSecondaryContainer,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      now.who,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: scheme.onSecondaryContainer,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      now.range,
                      style: TextStyle(
                        fontSize: 14,
                        color: scheme.onSecondaryContainer,
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 14),
            if (plan.next.isEmpty)
              Text('Další služby zatím nejsou naplánované.', style: muted)
            else ...[
              Text(
                'Další',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              for (final (i, entry) in plan.next.indexed) ...[
                if (i > 0) const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: _DutyNextRow(entry: entry),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

/// One of the duty card's „Další“ rows: the range on the left, the names
/// on the right — a long list wraps under itself, the range keeps its
/// line. A drawer too narrow for both side by side (one column of many
/// days) puts the names under the range.
class _DutyNextRow extends StatelessWidget {
  const _DutyNextRow({required this.entry});

  /// Under this width the names would get little or no room beside the
  /// range (some 140 px of it).
  static const stackBelow = 280.0;

  final KioskDutyEntry entry;

  @override
  Widget build(BuildContext context) {
    final range = Text(entry.range, style: const TextStyle(fontSize: 15));
    const namesStyle = TextStyle(fontSize: 15, fontWeight: FontWeight.w600);
    return LayoutBuilder(
      builder: (context, constraints) => constraints.maxWidth < stackBelow
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [range, Text(entry.who, style: namesStyle)],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                range,
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    entry.who,
                    textAlign: TextAlign.end,
                    style: namesStyle,
                  ),
                ),
              ],
            ),
    );
  }
}

const _noticeTitleStyle = TextStyle(fontSize: 20, fontWeight: FontWeight.w800);
const _noticeBodyStyle = TextStyle(fontSize: 16, height: 1.3);
const _noticeFooterHeight = 32.0;

/// The notices, one at a time. A single notice just stays; several take
/// turns every [turn], with dots to say how many there are. What does not
/// fit the card is cut, and only then „Více“ offers the full text.
class _NoticesCard extends StatefulWidget {
  const _NoticesCard({
    required this.notices,
    required this.turn,
    required this.fill,
    required this.onOpen,
  });

  final List<Message> notices;
  final Duration turn;
  final bool fill;
  final void Function(Message notice) onOpen;

  @override
  State<_NoticesCard> createState() => _NoticesCardState();
}

class _NoticesCardState extends State<_NoticesCard> {
  Timer? _timer;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(_NoticesCard old) {
    super.didUpdateWidget(old);
    if (old.turn != widget.turn) _start();
  }

  void _start() {
    _timer?.cancel();
    _timer = Timer.periodic(widget.turn, (_) => _step(1));
  }

  /// To the next ([direction] 1) or previous (-1) notice — on the timer or
  /// by a swipe; either way the next turn is a whole [turn] away.
  void _step(int direction) {
    if (!mounted || widget.notices.length < 2) return;
    final n = widget.notices.length;
    setState(() => _index = (_index + direction) % n);
    _start();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final notices = widget.notices;
    final scheme = Theme.of(context).colorScheme;
    final m = notices[_index.clamp(0, notices.length - 1)];
    return KioskCard(
      icon: Icons.campaign_outlined,
      title: 'NÁSTĚNKA',
      fill: widget.fill,
      child: _Swipe(
        onSwipe: _step,
        child: LayoutBuilder(
          builder: (context, box) {
            final fit = _fitNotice(context, m, box);
            // Only a cut notice has more to read; a whole one is not a link.
            return InkWell(
              onTap: fit.truncated ? () => widget.onOpen(m) : null,
              borderRadius: BorderRadius.circular(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: widget.fill ? MainAxisSize.max : MainAxisSize.min,
                children: [
                  SizedBox(
                    height: fit.height,
                    child: ClipRect(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        layoutBuilder: (current, previous) => Stack(
                          alignment: Alignment.topLeft,
                          children: [...previous, ?current],
                        ),
                        child: Column(
                          key: ValueKey(m.id),
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              m.title ?? '',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: _noticeTitleStyle,
                            ),
                            const SizedBox(height: 6),
                            Text(
                              m.body,
                              maxLines: fit.bodyLines,
                              // An ellipsis without a line limit makes Skia
                              // cut the text to its first line.
                              overflow: fit.bodyLines == null
                                  ? TextOverflow.clip
                                  : TextOverflow.ellipsis,
                              style: _noticeBodyStyle,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (widget.fill)
                    const Spacer()
                  else
                    const SizedBox(height: 8),
                  SizedBox(
                    height: _noticeFooterHeight - 8,
                    child: Row(
                      children: [
                        for (
                          var i = 0;
                          notices.length > 1 && i < notices.length;
                          i++
                        )
                          Container(
                            width: 8,
                            height: 8,
                            margin: const EdgeInsets.only(right: 6),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: i == _index
                                  ? scheme.primary
                                  : scheme.onSurfaceVariant.withValues(
                                      alpha: 0.35,
                                    ),
                            ),
                          ),
                        const Spacer(),
                        if (fit.truncated) ...[
                          Text(
                            'Více',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: scheme.primary,
                            ),
                          ),
                          Icon(
                            Icons.expand_more,
                            size: 20,
                            color: scheme.primary,
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  /// How much of [m] fits [box] (the card's interior): the height of the
  /// text block, the body lines that fit, and whether anything is cut. An
  /// unbounded box (a lone notice card) shows everything.
  ({double height, int? bodyLines, bool truncated}) _fitNotice(
    BuildContext context,
    Message m,
    BoxConstraints box,
  ) {
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    // The same style the Text widgets resolve: theirs merged into the
    // ambient one, or the measure would differ from what is drawn.
    final base = DefaultTextStyle.of(context).style;
    TextPainter paint(String text, TextStyle style, int? maxLines) =>
        TextPainter(
          text: TextSpan(text: text, style: base.merge(style)),
          textDirection: direction,
          textScaler: scaler,
          maxLines: maxLines,
        )..layout(maxWidth: box.maxWidth);

    final title = paint(m.title ?? '', _noticeTitleStyle, 2);
    final body = paint(m.body, _noticeBodyStyle, null);
    final natural = title.height + 6 + body.height;
    final available = box.hasBoundedHeight
        ? box.maxHeight - _noticeFooterHeight
        : double.infinity;
    if (natural <= available) {
      return (height: natural, bodyLines: null, truncated: false);
    }
    final line = paint('A', _noticeBodyStyle, 1).height;
    final lines = math.max(1, ((available - title.height - 6) / line).floor());
    return (height: math.max(available, 0), bodyLines: lines, truncated: true);
  }
}

/// The finished and the coming matches of the weeks the admin chose,
/// chronological, opened on the first one not decided yet. „Zobrazit další“
/// at either end brings one more week of the season; a tap on a finished
/// match opens its Zápis.
class _MatchesCard extends ConsumerStatefulWidget {
  const _MatchesCard({
    super.key,
    required this.onOpen,
    this.onPlay,
    this.boardDays,
    this.onShowLive,
  });

  final void Function(PrioritySlot match) onOpen;

  /// ▶ at a match with a video; null = no ▶ (the streams off).
  final void Function(PrioritySlot match)? onPlay;

  /// Back to the match being played; null when none is.
  final VoidCallback? onShowLive;

  /// The days the board shows after a visitor scrolled it; the list turns
  /// to the first match among them.
  final ({Day first, Day last})? boardDays;

  @override
  ConsumerState<_MatchesCard> createState() => _MatchesCardState();
}

class _MatchesCardState extends ConsumerState<_MatchesCard> {
  int _extraBack = 0;
  int _extraAhead = 0;

  /// The first match below the bottom edge when the list opened (see
  /// [kioskFirstUpcomingIndex]); null when none is coming. The list grows away from it in both
  /// directions, so what was on screen stays where it was when more weeks
  /// load (older matches grow upwards from here, not by shifting the rest).
  String? _anchorId;
  final _centerKey = GlobalKey();
  final _controller = ScrollController();
  bool _opened = false;

  /// One key per match row, to scroll a row into view.
  final _rowKeys = <String, GlobalKey>{};

  @override
  void didUpdateWidget(_MatchesCard old) {
    super.didUpdateWidget(old);
    final days = widget.boardDays;
    if (days != null && days != old.boardDays) _follow(old.boardDays, days);
  }

  /// Brings into view the matches of the days the board just brought into
  /// view ([kioskNewlyShownDays]) — and scrolls no further than that: a
  /// day back usually shows a day whose matches are on the list already,
  /// and the list stays; day by day the list follows, a match at a time.
  /// (It used to turn the first match of the board's days to the top on
  /// every scroll, so the list jumped even for a day it already showed.)
  /// The list widens by whole weeks when those matches lie outside it.
  void _follow(
    ({Day first, Day last})? previous,
    ({Day first, Day last}) days,
  ) {
    final now = ref.read(nowProvider).value ?? DateTime.now();
    final shown = kioskNewlyShownDays(
      previous,
      days,
      today: Day.fromDateTime(now),
    );
    if (shown == null) return;
    bool inDays(PrioritySlot s) =>
        !s.date.isBefore(shown.first) && !s.date.isAfter(shown.last);
    var back = _extraBack;
    var ahead = _extraAhead;
    var found = const <PrioritySlot>[];
    for (var i = 0; i < 60; i++) {
      final w = _window(back, ahead, watch: false);
      found = w.matches.where(inDays).toList();
      if (found.isNotEmpty) break;
      final earlier =
          w.matches.isEmpty || shown.first.isBefore(w.matches.first.date);
      if (earlier && w.moreBefore) {
        back++;
      } else if (!earlier && w.moreAfter) {
        ahead++;
      } else {
        break;
      }
    }
    if (found.isEmpty) return;
    if (back != _extraBack || ahead != _extraAhead) {
      setState(() {
        _extraBack = back;
        _extraAhead = ahead;
      });
    }
    final firstId = found.first.id;
    final lastId = found.last.id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients) return;
      final first = _rowKeys[firstId]?.currentContext?.findRenderObject();
      final last = _rowKeys[lastId]?.currentContext?.findRenderObject();
      if (first == null || last == null) return;
      final viewport = RenderAbstractViewport.of(first);
      final p = _controller.position;
      // The least scroll that shows them all: down until the last one's
      // bottom edge is in, then up until the first one's top edge is —
      // the first wins when they do not all fit.
      var target = p.pixels;
      final lastAtBottom = viewport.getOffsetToReveal(last, 1).offset;
      if (target < lastAtBottom) target = lastAtBottom;
      final firstAtTop = viewport.getOffsetToReveal(first, 0).offset;
      if (target > firstAtTop) target = firstAtTop;
      target = target.clamp(p.minScrollExtent, p.maxScrollExtent);
      if ((target - p.pixels).abs() < 0.5) return;
      _controller.animateTo(
        target,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeInOutCubic,
      );
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// The window for [extraBack]/[extraAhead] more weeks, from the current
  /// providers; [watch] subscribes the build, a tap only reads.
  KioskMatchWindow _window(
    int extraBack,
    int extraAhead, {
    required bool watch,
  }) {
    final settings =
        (watch ? ref.watch(settingsProvider) : ref.read(settingsProvider))
            .value;
    final now = (watch ? ref.watch(nowProvider) : ref.read(nowProvider)).value;
    return kioskMatchWindow(
      slots: watch
          ? ref.watch(prioritySlotsProvider)
          : ref.read(prioritySlotsProvider),
      today: Day.fromDateTime(now ?? DateTime.now()),
      weeksBack: settings?.kioskWeeksBack ?? 2,
      weeksAhead: settings?.kioskWeeksAhead ?? 1,
      showUpcoming: settings?.kioskShowUpcoming ?? true,
      extraBack: extraBack,
      extraAhead: extraAhead,
    );
  }

  /// „Zobrazit předchozí/další“: widens the window by whole weeks until a
  /// match shows up — a week with none (a holiday, a free round) would
  /// otherwise answer a tap with nothing — or the season has no more.
  void _more({required bool older}) {
    final shown = _window(_extraBack, _extraAhead, watch: false).matches.length;
    var back = _extraBack;
    var ahead = _extraAhead;
    while (true) {
      if (older) {
        back++;
      } else {
        ahead++;
      }
      final w = _window(back, ahead, watch: false);
      if (w.matches.length > shown || !(older ? w.moreBefore : w.moreAfter)) {
        break;
      }
    }
    setState(() {
      _extraBack = back;
      _extraAhead = ahead;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final now = ref.watch(nowProvider).value ?? DateTime.now();
    final today = Day.fromDateTime(now);
    final results =
        ref.watch(matchResultsProvider).value ?? const <String, MatchResult>{};
    final window = _window(_extraBack, _extraAhead, watch: true);
    final matches = window.matches;
    final onPlay = widget.onPlay;

    // Like Výsledky: opens with the first coming match at the bottom edge
    // and as many played (and playing) ones as fit above it. Afterwards the
    // same match stays the anchor (found by id, as more weeks are added).
    if (!_opened && matches.isNotEmpty) {
      final first = kioskFirstUpcomingIndex(matches, results, today);
      _anchorId = first < matches.length ? matches[first].id : null;
    }
    final anchor = _anchorId == null
        ? -1
        : matches.indexWhere((m) => m.id == _anchorId);
    // The centre sliver starts with the first coming match; offset 0 puts
    // it at the top edge, so the opening jump goes up one viewport and
    // leaves it just below the bottom one.
    final split = anchor < 0 ? matches.length : anchor;
    if (!_opened && matches.isNotEmpty) {
      _opened = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_controller.hasClients) return;
        final p = _controller.position;
        _controller.jumpTo(math.max(-p.viewportDimension, p.minScrollExtent));
      });
    }
    // Index 0 of the part before the centre is the last match above it.
    final older = matches.sublist(0, split).reversed.toList();
    final newer = matches.sublist(split);

    Widget row(PrioritySlot s) => SizedBox(
      key: _rowKeys.putIfAbsent(s.id, GlobalKey.new),
      height: _resultRowHeight,
      child: _MatchRow(
        slot: s,
        result: results[s.id],
        onOpen: widget.onOpen,
        play: onPlay != null && hasKioskVideo(s)
            ? (
                label: kioskStreamLabel(s, results[s.id], now),
                onPlay: () => onPlay(s),
              )
            : null,
      ),
    );
    Widget more(String label, VoidCallback onTap) => SizedBox(
      height: _moreRowHeight,
      child: Center(
        child: TextButton(onPressed: onTap, child: Text(label)),
      ),
    );

    final showLive = widget.onShowLive;
    return KioskCard(
      icon: Icons.emoji_events_outlined,
      title: 'ZÁPASY',
      // A match is being played: back to it.
      action: showLive == null
          ? null
          : ActionChip(
              avatar: Icon(Icons.circle, size: 10, color: scheme.error),
              label: const Text('Právě se hraje'),
              visualDensity: VisualDensity.compact,
              onPressed: showLive,
            ),
      fill: true,
      child: matches.isEmpty
          ? Text(
              'V tomhle období není žádný zápas.',
              style: TextStyle(color: scheme.onSurfaceVariant),
            )
          : CustomScrollView(
              controller: _controller,
              center: _centerKey,
              // Every row built, so following the board can scroll to any.
              // (Deprecated on newer stable Flutter for scrollCacheExtent,
              // which the SDK this repo builds with locally lacks — CI runs
              // the newer one.)
              // ignore: deprecated_member_use
              cacheExtent: 100000,
              slivers: [
                SliverList.builder(
                  itemCount: older.length + (window.moreBefore ? 1 : 0),
                  itemBuilder: (context, i) => i < older.length
                      ? row(older[i])
                      : more('Zobrazit předchozí', () => _more(older: true)),
                ),
                SliverList.list(
                  key: _centerKey,
                  children: [
                    for (final s in newer) row(s),
                    if (window.moreAfter)
                      more('Zobrazit další', () => _more(older: false)),
                  ],
                ),
              ],
            ),
    );
  }
}

class _MatchRow extends StatelessWidget {
  const _MatchRow({
    required this.slot,
    required this.onOpen,
    this.result,
    this.play,
  });

  final PrioritySlot slot;
  final MatchResult? result;
  final void Function(PrioritySlot match) onOpen;

  /// A match with a video: ▶ at the row's end, [label] its tooltip.
  final ({String label, VoidCallback onPlay})? play;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasScore = hasScoreData(result);
    final score = hasScore
        ? pointsLabel(result!.homePoints, result!.awayPoints)
        : null;
    final when =
        '${dayLabel(slot.date)}'
        '${slot.timeKnown ? ' ${slot.startsAt.display()}' : ''}';
    final row = Row(
      children: [
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MatchTitle(
                slot: slot,
                winner: displayWinner(result),
                style: const TextStyle(fontSize: 15),
              ),
              EmojiText(
                '${slot.isAway ? '' : '🏠 '}$when',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        if (score != null) ...[
          const SizedBox(width: 10),
          Text(
            score,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: scheme.primary,
            ),
          ),
        ],
      ],
    );
    // Only a match with a score has a Zápis to open.
    final body = !hasScore
        ? row
        : InkWell(
            onTap: () => onOpen(slot),
            borderRadius: BorderRadius.circular(8),
            child: row,
          );
    final play = this.play;
    if (play == null) return body;
    return Row(
      children: [
        Expanded(child: body),
        IconButton(
          tooltip: play.label,
          onPressed: play.onPlay,
          color: scheme.primary,
          icon: const Icon(Icons.play_circle_outline),
        ),
      ],
    );
  }
}

/// The match being played across the whole drawer, the Souboje view of the
/// match detail: the scoreboard, one card per duel, the team totals. Several
/// live matches take turns every [turn].
class _LiveView extends ConsumerStatefulWidget {
  const _LiveView({
    required this.matches,
    required this.turn,
    required this.onOpenMatch,
    this.onPlay,
    this.onShowList,
  });

  /// To the list of matches; null when there is none to show.
  final VoidCallback? onShowList;

  /// A tap on the score: the match's Zápis.
  final void Function(PrioritySlot match) onOpenMatch;

  /// ▶ at the match on screen, when it has a video: its stream; null =
  /// no badge (the streams off).
  final void Function(PrioritySlot match)? onPlay;

  final List<PrioritySlot> matches;
  final Duration turn;

  @override
  ConsumerState<_LiveView> createState() => _LiveViewState();
}

class _LiveViewState extends ConsumerState<_LiveView> {
  Timer? _timer;
  int _index = 0;

  /// The way the last change went: 1 to the next match, -1 back — the
  /// cards slide in from that side.
  int _direction = 1;

  /// The match a visitor pinned (a tap on the dots): no turns until it ends
  /// — it then drops out of the live matches, and the lock with it.
  String? _lockedId;

  /// Asks the server for fresh scores of the matches being played, every
  /// [_refreshEvery] (the admin's choice).
  Timer? _refresh;
  Duration? _refreshEvery;

  /// The matches a visitor tapped the age line of, each with the fetch time
  /// on screen when asked: their ⟳ turns until that time moves on, the
  /// answer says nothing will come, or [kioskRefreshWait] runs out. The
  /// clock's own asks go unseen.
  final _asking = <String, ({DateTime? fetched, Object ask})>{};
  final _askTimeouts = <String, Timer>{};

  void _armRefresh(Duration every) {
    if (_refreshEvery == every) return;
    _refreshEvery = every;
    _refresh?.cancel();
    void askAll() {
      final ask = ref.read(kioskRefreshMatchProvider);
      for (final m in widget.matches) {
        unawaited(ask(m.id).then<void>((_) {}, onError: (Object _) {}));
      }
    }

    _refresh = Timer.periodic(every, (_) => askAll());
    // And once now: the score on screen is as old as it is.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) askAll();
    });
  }

  /// A visitor's ask for [id]'s score; a second tap while one is out
  /// waits for it.
  Future<void> _ask(String id) async {
    if (_asking.containsKey(id)) return;
    final asked = ref.read(kioskRefreshMatchProvider);
    // This ask's own token: an answer that comes after it timed out ends
    // only itself, never a later tap's.
    final ask = Object();
    setState(() {
      _asking[id] = (
        fetched: ref.read(matchResultsProvider).value?[id]?.fetchedAt,
        ask: ask,
      );
    });
    _askTimeouts[id] = Timer(kioskRefreshWait, () => _asked(id, ask));
    final (status, _) = await (
      asked(id).then<String?>((s) => s, onError: (Object _) => null),
      Future<void>.delayed(kioskRefreshMinSpin),
    ).wait;
    // Queued: the fetch's arrival ends the wait (build's listener). Fresh,
    // not live, or failed: nothing more is coming.
    if (status != 'queued') _asked(id, ask);
  }

  /// [id]'s ask is over — only [ask] when given, the current one if not.
  void _asked(String id, [Object? ask]) {
    final current = _asking[id];
    if (current == null || (ask != null && current.ask != ask)) return;
    _askTimeouts.remove(id)?.cancel();
    if (mounted) setState(() => _asking.remove(id));
  }

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(_LiveView old) {
    super.didUpdateWidget(old);
    if (old.turn != widget.turn) _start();
  }

  /// (Re)starts the wait for the next turn — also on every touch or scroll
  /// in the view: whoever is reading a match keeps it on screen.
  void _start() {
    _timer?.cancel();
    _timer = Timer.periodic(widget.turn, (_) => _step(1));
  }

  /// To the next ([direction] 1) or previous (-1) live match — on the timer
  /// or by a swipe; either way the next turn is a whole turn away.
  void _step(int direction, {bool byHand = false}) {
    if (!mounted || widget.matches.length < 2) return;
    if (_locked && !byHand) return;
    setState(() {
      // A swipe moves on, and takes the lock off.
      _lockedId = null;
      _direction = direction;
      _index = (_index + direction) % widget.matches.length;
    });
    _start();
  }

  bool get _locked =>
      _lockedId != null && widget.matches.any((m) => m.id == _lockedId);

  void _toggleLock(String id) {
    setState(() => _lockedId = _lockedId == id ? null : id);
    _start();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _refresh?.cancel();
    for (final t in _askTimeouts.values) {
      t.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final matches = widget.matches;
    final refreshEvery = Duration(
      seconds: ref.watch(settingsProvider).value?.kioskLiveRefreshSeconds ?? 60,
    );
    _armRefresh(refreshEvery);
    // A fetch landed: the ⟳ of its match stops.
    ref.listen(matchResultsProvider, (_, next) {
      final results = next.value ?? const {};
      for (final MapEntry(key: id, value: asked) in [..._asking.entries]) {
        if (results[id]?.fetchedAt != asked.fetched) _asked(id);
      }
    });
    // A locked match stays on screen wherever the list puts it.
    final lockedAt = _locked
        ? matches.indexWhere((m) => m.id == _lockedId)
        : -1;
    if (lockedAt >= 0) _index = lockedAt;
    final slot = matches[_index.clamp(0, matches.length - 1)];
    final onPlay = widget.onPlay;
    final current = ValueKey(slot.id);
    final locked = lockedAt >= 0;
    return Listener(
      onPointerDown: (_) => _start(),
      behavior: HitTestBehavior.translucent,
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n is UserScrollNotification) _start();
          return false;
        },
        child: _Swipe(
          onSwipe: (d) => _step(d, byHand: true),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Back to all matches on the left, the dots (how many take
                // turns; the lock) in the middle, how old the score is on
                // the right. (The scoreboard's own chip says it is live.)
                // Three slots, the room left over shared evenly between
                // them: the age and the badge end flush at the right edge
                // however wide the drawer — the absent back button or dots
                // keep their slot as nothing.
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    if (widget.onShowList != null)
                      IconButton(
                        tooltip: 'Všechny zápasy',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.arrow_back),
                        onPressed: widget.onShowList,
                      )
                    else
                      const SizedBox.shrink(),
                    // The dots say how many matches take turns; a tap
                    // pins the one on screen until it ends (or another
                    // tap, or a swipe).
                    if (matches.length > 1)
                      Semantics(
                        button: true,
                        label: locked
                            ? 'Odemknout zápas'
                            : 'Zamknout tento zápas',
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _toggleLock(slot.id),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 8,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 200),
                                  child: Icon(
                                    locked ? Icons.lock : Icons.lock_open,
                                    key: ValueKey(locked),
                                    size: 16,
                                    color: locked
                                        ? scheme.primary
                                        : scheme.onSurfaceVariant.withValues(
                                            alpha: 0.5,
                                          ),
                                  ),
                                ),
                                for (var i = 0; i < matches.length; i++)
                                  AnimatedContainer(
                                    duration: const Duration(milliseconds: 300),
                                    width: i == _index ? 18 : 8,
                                    height: 8,
                                    margin: const EdgeInsets.only(left: 6),
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(4),
                                      color: i == _index
                                          ? scheme.primary
                                          : scheme.onSurfaceVariant.withValues(
                                              alpha: 0.35,
                                            ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      )
                    else
                      const SizedBox.shrink(),
                    // The only slot that gives way, and only the age in it:
                    // it takes the width it needs and is cut short only
                    // when the drawer has nothing left — the badge beside
                    // it is the stream's only way in. (A flex child next to
                    // Spacers would get a fixed share of the room instead:
                    // cut short with room to spare, or ending short of the
                    // edge.)
                    Flexible(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: _LiveAge(
                              slot: slot,
                              refreshing: _asking.containsKey(slot.id),
                              onRefresh: () => unawaited(_ask(slot.id)),
                            ),
                          ),
                          // The live badge everywhere else has: the pulsing
                          // red camera — still with the admin's animations
                          // off.
                          if (onPlay != null && hasKioskVideo(slot)) ...[
                            const SizedBox(width: 4),
                            MatchLeading(
                              slot: slot,
                              result: ref.watch(
                                matchResultsProvider.select(
                                  (r) => r.value?[slot.id],
                                ),
                              ),
                              now:
                                  ref.watch(nowProvider).value ?? DateTime.now(),
                              linksEnabled: true,
                              fallback: const SizedBox.shrink(),
                              launch: (_) => onPlay(slot),
                              pulse: ref.watch(
                                settingsProvider.select(
                                  (s) => s.value?.kioskAnimations ?? true,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: ClipRect(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 380),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      layoutBuilder: (current, previous) => Stack(
                        fit: StackFit.expand,
                        children: [...previous, ?current],
                      ),
                      // The new match slides in from the side it comes from,
                      // the old one out the other way, both fading.
                      transitionBuilder: (child, animation) {
                        final incoming = child.key == current;
                        final from = incoming ? _direction : -_direction;
                        return SlideTransition(
                          position: Tween(
                            begin: Offset(0.35 * from, 0),
                            end: Offset.zero,
                          ).animate(animation),
                          child: FadeTransition(
                            opacity: animation,
                            child: child,
                          ),
                        );
                      },
                      child: _LiveMatch(
                        key: current,
                        slot: slot,
                        onOpenMatch: widget.onOpenMatch,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// How old the score on screen is — „⟳ před 3 min“ — and the button that
/// asks for a fresh one: a tap does what the kiosk's clock does every
/// refresh interval. The ⟳ turns while the tapped-for score is on its way;
/// the clock's quiet asks leave it still.
class _LiveAge extends ConsumerStatefulWidget {
  const _LiveAge({
    required this.slot,
    required this.refreshing,
    required this.onRefresh,
  });

  final PrioritySlot slot;
  final bool refreshing;
  final VoidCallback onRefresh;

  @override
  ConsumerState<_LiveAge> createState() => _LiveAgeState();
}

class _LiveAgeState extends ConsumerState<_LiveAge>
    with SingleTickerProviderStateMixin {
  late final _spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  );

  @override
  void initState() {
    super.initState();
    if (widget.refreshing) _spin.repeat();
  }

  @override
  void didUpdateWidget(_LiveAge old) {
    super.didUpdateWidget(old);
    // Also mid-finish: an ask that starts while the last one's turn runs
    // out turns again (repeat cancels the finish and its reset).
    if (widget.refreshing && (!old.refreshing || !_spin.isAnimating)) {
      _spin.repeat();
    } else if (!widget.refreshing && old.refreshing) {
      // Finishes the turn it is in rather than jump back upright.
      _spin.animateTo(1).then((_) {
        if (mounted && !widget.refreshing) _spin.value = 0;
      });
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final now = ref.watch(nowProvider).value ?? DateTime.now();
    final fetched = ref.watch(
      matchResultsProvider.select((r) => r.value?[widget.slot.id]?.fetchedAt),
    );
    if (fetched == null) return const SizedBox.shrink();
    final age = freshnessLabel(fetched, now);
    return Semantics(
      button: true,
      enabled: !widget.refreshing,
      onTap: widget.refreshing ? null : widget.onRefresh,
      label: widget.refreshing
          ? 'Obnovuji výsledky, $age'
          : 'Obnovit výsledky, $age',
      excludeSemantics: true,
      // Its own Material: the ripple would paint on the Scaffold's, under
      // the drawer's opaque background.
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          // While one is out, a tap would only ask again for the same.
          onTap: widget.refreshing ? null : widget.onRefresh,
          borderRadius: BorderRadius.circular(8),
          child: ConstrainedBox(
            // A finger's worth on a wall display, however short the text.
            constraints: const BoxConstraints(minHeight: 48),
            // Room to the left only: the text still ends flush with the
            // header's right edge (or against the live badge).
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Its own layer: a turn repaints the icon, not the drawer.
                  RepaintBoundary(
                    child: RotationTransition(
                      turns: _spin,
                      child: Icon(
                        Icons.refresh,
                        size: 18,
                        color: widget.refreshing
                            ? scheme.primary
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      age,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One live match: its scoreboard stays on top, the duels and the team
/// totals scroll under it — opened on the last duel played or being
/// played, the earlier ones above it.
class _LiveMatch extends ConsumerStatefulWidget {
  const _LiveMatch({super.key, required this.slot, required this.onOpenMatch});

  final void Function(PrioritySlot match) onOpenMatch;

  final PrioritySlot slot;

  @override
  ConsumerState<_LiveMatch> createState() => _LiveMatchState();
}

class _LiveMatchState extends ConsumerState<_LiveMatch> {
  final _expanded = <int>{};
  final _duelKeys = <int, GlobalKey>{};
  bool _scrolled = false;

  @override
  Widget build(BuildContext context) {
    final slot = widget.slot;
    final now = ref.watch(nowProvider).value ?? DateTime.now();
    final result = ref.watch(
      matchResultsProvider.select((r) => r.value?[slot.id]),
    );
    final players =
        ref.watch(matchPlayerResultsProvider(slot.id)).value ?? const [];
    final duels = duelsOf(players);
    final scale = diffScale(duels);

    // Duels are played in groups, two on a four-lane alley, three on a
    // six-lane one: open on the group the play has reached, its first card
    // whole at the top (a card cut at the bottom is the lesser evil).
    final target = kioskLiveScrollTarget(
      duels,
      laneCount: ref.watch(settingsProvider).value?.laneCount ?? 4,
    );
    if (!_scrolled && target != null) {
      _scrolled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final card = _duelKeys[target]?.currentContext;
        if (card == null || !card.mounted) return;
        Scrollable.ensureVisible(card);
      });
    }

    // The score opens the Zápis — when there are players to put in it.
    final zapis = players.isEmpty ? null : () => widget.onOpenMatch(slot);
    final layout =
        ref.watch(settingsProvider).value?.kioskLiveLayout ?? MatchLayout.full;
    if (layout != MatchLayout.full) {
      // The score pinned on top (a tap opens the Zápis), the duels fitted
      // under it. Zápis is not a kiosk layout (0064's check); drawn as the
      // table should a row ever carry it.
      final score = GestureDetector(
        onTap: zapis,
        // The teams as the app shows them: a club's nickname (0080).
        child: MatchScoreLine(
          slot: ref.watch(nameDisplayProvider).shown(slot),
          result: result,
          duels: duels,
        ),
      );
      return layout == MatchLayout.compact
          ? DuelsCompact(duels: duels, result: result, header: score)
          : DuelsTable(duels: duels, result: result, header: score);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GestureDetector(
          onTap: zapis,
          child: MatchScoreboard(
            slot: slot,
            result: result,
            players: players,
            now: now,
            homeColor: homeSideColor,
            awayColor: awaySideColor,
            // The row above says how old the score is.
            showFreshness: false,
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final duel in duels)
                  Padding(
                    key: _duelKeys.putIfAbsent(duel.position, GlobalKey.new),
                    padding: const EdgeInsets.only(top: 8),
                    child: DuelCard(
                      duel: duel,
                      scale: scale,
                      expanded: _expanded.contains(duel.position),
                      onTap: duel.state == DuelState.waiting
                          ? () {}
                          : () => setState(() {
                              if (!_expanded.remove(duel.position)) {
                                _expanded.add(duel.position);
                              }
                            }),
                      homeColor: homeSideColor,
                      awayColor: awaySideColor,
                      showSetPoints: setPointsMatter(result?.discipline),
                    ),
                  ),
                if (result != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: TeamTotalsCard(
                      result: result,
                      homeColor: homeSideColor,
                      awayColor: awaySideColor,
                      showSetPoints: setPointsMatter(result.discipline),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
