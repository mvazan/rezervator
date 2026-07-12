import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';
import '../../domain/schedule.dart';
import '../admin/widgets/block_dialog.dart';
import 'day_pager_view.dart';
import 'widgets/day_header.dart';
import 'widgets/gap_rows.dart';
import 'widgets/slot_tile.dart';

/// The two schedule layouts a device can be set to; persisted per-device via
/// [scheduleViewPrefKey].
enum ScheduleView { day, week }

/// shared_preferences key storing the chosen [ScheduleView] ('day'/'week').
const scheduleViewPrefKey = 'schedule_view';

/// shared_preferences key storing the per-device "fit width" boolean: when
/// true both schedule views drop horizontal scrolling and let lanes share the
/// full screen width (names ellipsis-clipped). Defaults to true on narrow
/// (< 700px) devices where the whole day rarely fits otherwise.
const scheduleFitWidthPrefKey = 'fit_width';

/// Live week view: grid computed by buildWeekSchedule, booking via RPCs.
/// Acts as the "shell": owns navigation (week offset, view toggle) and all
/// provider wiring; delegates rendering to [WeekListView] or [DayPagerView],
/// which both receive the same pre-computed [WeekSchedule] and handlers.
class WeekScreen extends ConsumerStatefulWidget {
  const WeekScreen({super.key});

  @override
  ConsumerState<WeekScreen> createState() => _WeekScreenState();
}

class _WeekScreenState extends ConsumerState<WeekScreen> {
  int _weekOffset = 0;
  int _dayIndex = 0;

  /// Null until the stored preference (or the width-based default) has been
  /// resolved on the first frame — see [_resolveInitialView].
  ScheduleView? _view;

  /// Null until the stored `fit_width` preference (or the width-based default)
  /// has been resolved on the first frame — see [_resolveInitialView].
  bool? _fitWidth;

  Day _monday(Day today) => today.addDays(1 - today.weekday + 7 * _weekOffset);

  @override
  void initState() {
    super.initState();
    _dayIndex = Day.fromDateTime(DateTime.now()).weekday - 1;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Only the very first call (before the pref lookup resolves _view) needs
    // the current width — captured here (safe: no async gap yet) so
    // _resolveInitialView never has to read `context` after an `await`.
    if (_view == null) {
      final narrow = MediaQuery.sizeOf(context).width < 700;
      _resolveInitialView(
        narrow ? ScheduleView.day : ScheduleView.week,
        // Fit-width is most useful on phones, so it defaults on when narrow.
        fitWidthDefault: narrow,
      );
    }
  }

  /// Reads the stored `schedule_view` preference; if absent, uses
  /// [widthDefault] (`day` under 700px width, `week` otherwise — spec §3).
  /// Falls back to [widthDefault] if reading the preference throws (e.g.
  /// platform channel unavailable) so the screen never gets stuck without a
  /// view.
  Future<void> _resolveInitialView(
    ScheduleView widthDefault, {
    required bool fitWidthDefault,
  }) async {
    ScheduleView resolved;
    bool fitWidth;
    try {
      final prefs = await SharedPreferences.getInstance();
      resolved = switch (prefs.getString(scheduleViewPrefKey)) {
        'day' => ScheduleView.day,
        'week' => ScheduleView.week,
        _ => widthDefault,
      };
      fitWidth = prefs.getBool(scheduleFitWidthPrefKey) ?? fitWidthDefault;
    } catch (_) {
      resolved = widthDefault;
      fitWidth = fitWidthDefault;
    }
    if (mounted) {
      setState(() {
        _view = resolved;
        _fitWidth = fitWidth;
      });
    }
  }

  Future<void> _setFitWidth(bool fitWidth) async {
    setState(() => _fitWidth = fitWidth);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(scheduleFitWidthPrefKey, fitWidth);
    } catch (_) {
      // Persistence is a per-device nicety; a failed write just means the
      // next launch falls back to the width-based default.
    }
  }

  Future<void> _setView(ScheduleView view) async {
    setState(() => _view = view);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        scheduleViewPrefKey,
        view == ScheduleView.day ? 'day' : 'week',
      );
    } catch (_) {
      // Persistence is a per-device nicety; a failed write just means the
      // next launch falls back to the width-based default.
    }
  }

  Future<void> _book(
    Day date,
    TimeBlock block,
    int lane,
    Profile me,
    bool isAdmin,
  ) async {
    final message = '${dayFull(date)} · ${block.label} · Dráha $lane';
    String? playerId;
    if (isAdmin) {
      playerId = await showDialog<String>(
        context: context,
        builder: (dialogContext) => _BookingDialog(
          message: message,
          me: me,
          players: ref.read(playersProvider).value ?? const [],
        ),
      );
    } else {
      final confirmed = await confirmDialog(
        context,
        title: 'Rezervovat termín?',
        message: message,
        confirmLabel: 'Rezervovat',
      );
      playerId = confirmed ? me.id : null;
    }
    if (playerId == null || !mounted) return;
    await tryAction(
      context,
      () => Api.createReservation(
        playerId: playerId!,
        date: date,
        blockId: block.id,
        lane: lane,
      ),
      success: 'Zarezervováno.',
      errorText: friendlyDbError,
    );
  }

  Future<void> _cancel(
    Day date,
    TimeBlock block,
    Reservation r, {
    required bool ownFuture,
  }) async {
    if (ownFuture) {
      final ok = await confirmDialog(
        context,
        title: 'Zrušit rezervaci?',
        message: '${dayFull(date)} · ${block.label} · Dráha ${r.lane}',
        confirmLabel: 'Zrušit rezervaci',
        cancelLabel: 'Zpět',
      );
      if (!ok || !mounted) return;
      await tryAction(
        context,
        () => Api.cancelReservation(r.id),
        success: 'Rezervace zrušena.',
        errorText: friendlyDbError,
      );
      return;
    }
    final note = await promptText(
      context,
      title: 'Zrušit rezervaci — poznámka',
      hint: 'nepřišel',
      confirmLabel: 'Zrušit rezervaci',
    );
    if (note == null || !mounted) return;
    await tryAction(
      context,
      () => Api.cancelReservation(r.id, note: note),
      success: 'Rezervace zrušena.',
      errorText: friendlyDbError,
    );
  }

  void _go(int delta) {
    setState(() {
      _weekOffset = delta == 0 ? 0 : _weekOffset + delta;
      if (delta == 0) {
        _dayIndex = Day.fromDateTime(DateTime.now()).weekday - 1;
      }
    });
    // Views cannot stream (see playersProvider doc), so an explicit refresh
    // on navigation is the only way approved-after-start players stop
    // rendering as '?' without a full app restart.
    ref.invalidate(playersProvider);
  }

  /// Called by [DayPagerView] when a swipe crosses the Monday/Sunday edge:
  /// [weekDelta] is +1/-1 and [landingDayIndex] (0=Mon..6=Sun) is the day to
  /// land on in the adjacent week (Sunday when moving back, Monday when
  /// moving forward).
  void _shiftWeek(int weekDelta, int landingDayIndex) {
    setState(() {
      _weekOffset += weekDelta;
      _dayIndex = landingDayIndex;
    });
    ref.invalidate(playersProvider);
  }

  void _selectDay(int dayIndex) => setState(() => _dayIndex = dayIndex);

  @override
  Widget build(BuildContext context) {
    final nowDt = DateTime.now();
    final todayDay = Day.fromDateTime(nowDt);
    final now = HourMinute(nowDt.hour, nowDt.minute);
    final monday = _monday(todayDay);
    final view = _view;
    final fitWidth = _fitWidth ?? false;

    final settings =
        ref.watch(settingsProvider).value ?? ScheduleSettings.defaults;
    final timeBlocks = ref.watch(timeBlocksProvider);
    final overrides = ref.watch(dayOverridesProvider).value ?? const [];
    final priority = ref.watch(prioritySlotsProvider);
    final rentals = ref.watch(rentalsProvider).value ?? const [];
    final weekReservations = ref.watch(weekReservationsProvider(monday));
    final players = ref.watch(playersProvider).value ?? const [];
    final me = ref.watch(myProfileProvider).value;
    final mine = ref.watch(myActiveReservationsProvider).value ?? const [];

    final header = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: () => _go(-1),
          ),
          Expanded(
            child: Text(
              rangeLabel(monday, monday.addDays(6)),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          if (_weekOffset != 0)
            TextButton(onPressed: () => _go(0), child: const Text('dnes')),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: () => _go(1),
          ),
          if (view != null)
            SegmentedButton<ScheduleView>(
              segments: const [
                ButtonSegment(
                  value: ScheduleView.day,
                  icon: Icon(Icons.calendar_view_day_outlined),
                  tooltip: 'Den',
                ),
                ButtonSegment(
                  value: ScheduleView.week,
                  icon: Icon(Icons.calendar_view_week_outlined),
                  tooltip: 'Týden',
                ),
              ],
              selected: {view},
              onSelectionChanged: (s) => _setView(s.single),
              showSelectedIcon: false,
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          if (_fitWidth != null)
            IconButton(
              icon: const Icon(Icons.fit_screen_outlined),
              isSelected: fitWidth,
              tooltip:
                  fitWidth ? 'Zpět na posuvnou mřížku' : 'Roztáhnout na šířku',
              onPressed: () => _setFitWidth(!fitWidth),
            ),
        ],
      ),
    );

    if (view == null || _fitWidth == null || timeBlocks.isLoading) {
      return Column(
        children: [
          header,
          const Expanded(child: Center(child: CircularProgressIndicator())),
        ],
      );
    }

    if (timeBlocks.hasError) {
      return Column(
        children: [
          header,
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Rozvrh se nepodařilo načíst.'),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: () => ref.invalidate(timeBlocksProvider),
                    child: const Text('Zkusit znovu'),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    final dbBlocks = timeBlocks.value ?? const [];
    final blocksFromDb = dbBlocks.isNotEmpty;
    final blocks = blocksFromDb ? dbBlocks : defaultTimeBlocks();
    final reservations = weekReservations.value ?? const [];
    // Cells stay inert while the placeholder grid is shown (placeholder ids
    // like 'default-N' are not UUIDs — the RPC would reject them with an
    // unmapped error; the placeholder only shows the shape of the schedule
    // before the backend is seeded) and while this week's reservations are
    // still loading/erroring (booking against a stale/absent view of who
    // already holds the slot would race the RPC's own authoritative check).
    final interactive = blocksFromDb && weekReservations.hasValue && me != null;

    final week = buildWeekSchedule(
      monday: monday,
      today: todayDay,
      now: now,
      settings: settings,
      blocks: blocks,
      overrides: overrides,
      priority: priority,
      rentals: rentals,
      reservations: reservations,
    );
    final myCount = me == null
        ? 0
        : activeReservationCount(mine, me.id, todayDay);
    // Prefer the board nick when set, matching the kiosk board.
    final nameById = {
      for (final p in players) p.id: p.nick.isNotEmpty ? p.nick : p.displayName,
    };
    final clubColorById = {for (final p in players) p.id: p.clubColor};
    final myCountByIndex = [
      for (var i = 0; i < 7; i++)
        _myLiveCountOn(mine, me?.id, monday.addDays(i)),
    ];

    void onBook(Day date, TimeBlock block, int lane) =>
        _book(date, block, lane, me!, me.isAdmin);
    void onCancel(
      Day date,
      TimeBlock block,
      Reservation r, {
      required bool ownFuture,
    }) => _cancel(date, block, r, ownFuture: ownFuture);
    // Admin block gestures (long-press edit, tap-a-gap add) only exist for
    // admins on the real DB block set — never on the placeholder grid.
    final canEditBlocks = (me?.isAdmin ?? false) && blocksFromDb;
    final onLongPressBlock = canEditBlocks
        ? (TimeBlock block) => showDialog<void>(
              context: context,
              builder: (_) => BlockDialog(existing: block, blocks: dbBlocks),
            )
        : null;
    final onAddBlockInGap = canEditBlocks
        ? (HourMinute start, HourMinute end) => showDialog<void>(
              context: context,
              builder: (_) => BlockDialog(
                existing: null,
                blocks: dbBlocks,
                initialStart: start,
                initialEnd: end,
              ),
            )
        : null;

    return Column(
      children: [
        header,
        Expanded(
          child: view == ScheduleView.week
              ? WeekListView(
                  week: week,
                  me: me,
                  myCount: myCount,
                  settings: settings,
                  nameById: nameById,
                  clubColorById: clubColorById,
                  interactive: interactive,
                  fitWidth: fitWidth,
                  onBook: onBook,
                  onCancel: onCancel,
                  onLongPressBlock: onLongPressBlock,
                  onAddBlockInGap: onAddBlockInGap,
                )
              : DayPagerView(
                  week: week,
                  fitWidth: fitWidth,
                  weekOffset: _weekOffset,
                  dayIndex: _dayIndex,
                  today: todayDay,
                  now: now,
                  settings: settings,
                  blocks: blocks,
                  overrides: overrides,
                  priority: priority,
                  rentals: rentals,
                  me: me,
                  myCount: myCount,
                  myCountByIndex: myCountByIndex,
                  nameById: nameById,
                  clubColorById: clubColorById,
                  interactive: interactive,
                  onBook: onBook,
                  onCancel: onCancel,
                  onSelectDay: _selectDay,
                  onShiftWeek: _shiftWeek,
                ),
        ),
      ],
    );
  }
}

/// Today's vertical week list: one card per day, each showing a compact
/// grid of [SlotTile]s. Receives the already-computed [week] and handlers
/// from the [WeekScreen] shell — no provider access of its own.
class WeekListView extends StatelessWidget {
  const WeekListView({
    super.key,
    required this.week,
    required this.me,
    required this.myCount,
    required this.settings,
    required this.nameById,
    required this.clubColorById,
    required this.interactive,
    required this.fitWidth,
    required this.onBook,
    required this.onCancel,
    this.onLongPressBlock,
    this.onAddBlockInGap,
  });

  final WeekSchedule week;
  final Profile? me;
  final int myCount;
  final ScheduleSettings settings;
  final Map<String, String> nameById;
  final Map<String, int> clubColorById;
  final bool interactive;

  /// When true the compact grid drops its horizontal scroller and lets lanes
  /// share the full width (names ellipsis-clipped); see [_DaySection._grid].
  final bool fitWidth;
  final void Function(Day, TimeBlock, int lane) onBook;
  final void Function(Day, TimeBlock, Reservation, {required bool ownFuture})
  onCancel;

  /// Admin-only (null otherwise): long-press a block's time label to edit
  /// it; tap an empty gap to add a block prefilled with the gap's range.
  final void Function(TimeBlock)? onLongPressBlock;
  final void Function(HourMinute start, HourMinute end)? onAddBlockInGap;

  @override
  Widget build(BuildContext context) {
    // Portrait phones get tighter list gutters so more of each day fits.
    final narrow = MediaQuery.sizeOf(context).width < 700;
    return ListView(
      padding: narrow
          ? const EdgeInsets.fromLTRB(6, 0, 6, 16)
          : const EdgeInsets.fromLTRB(12, 0, 12, 24),
      children: [
        for (final day in week.days)
          _DaySection(
            day: day,
            me: me,
            myCount: myCount,
            settings: settings,
            nameById: nameById,
            clubColorById: clubColorById,
            interactive: interactive,
            fitWidth: fitWidth,
            onBook: onBook,
            onCancel: onCancel,
            onLongPressBlock: onLongPressBlock,
            onAddBlockInGap: onAddBlockInGap,
          ),
      ],
    );
  }
}

class _DaySection extends StatelessWidget {
  const _DaySection({
    required this.day,
    required this.me,
    required this.myCount,
    required this.settings,
    required this.nameById,
    required this.clubColorById,
    required this.interactive,
    required this.fitWidth,
    required this.onBook,
    required this.onCancel,
    this.onLongPressBlock,
    this.onAddBlockInGap,
  });

  final DaySchedule day;
  final Profile? me;
  final int myCount;
  final ScheduleSettings settings;
  final Map<String, String> nameById;
  final Map<String, int> clubColorById;

  /// False while blocks are the placeholder grid or this week's reservation
  /// stream isn't loaded yet — see the doc comment in build() for why.
  final bool interactive;

  /// See [WeekListView.fitWidth].
  final bool fitWidth;
  final void Function(Day, TimeBlock, int lane) onBook;
  final void Function(Day, TimeBlock, Reservation, {required bool ownFuture})
  onCancel;

  /// See [WeekListView.onLongPressBlock]/[WeekListView.onAddBlockInGap].
  final void Function(TimeBlock)? onLongPressBlock;
  final void Function(HourMinute start, HourMinute end)? onAddBlockInGap;

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 700;
    return Card(
      child: Padding(
        padding: EdgeInsets.all(narrow ? 8 : 12),
        child: switch (day) {
          ClosedDay(:final reason) => DayHeader(
            date: day.date,
            priority: day.priority,
            closedReason: reason,
          ),
          OpenDay() => _openDay(context, day as OpenDay),
        },
      ),
    );
  }

  Widget _openDay(BuildContext context, OpenDay day) {
    final isAdmin = me?.isAdmin ?? false;
    final freeCount = day.blocks
        .expand(
          (block) => [
            for (var lane = 1; lane <= day.laneCount; lane++) (block, lane),
          ],
        )
        .where(
          (entry) => canBook(
            state: day.slot(entry.$1.id, entry.$2),
            myActiveCount: myCount,
            settings: settings,
            isAdmin: isAdmin,
          ),
        )
        .length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DayHeader(
          date: day.date,
          priority: day.priority,
          chipLabel: '$freeCount volných',
        ),
        const SizedBox(height: 6),
        _grid(context, day),
      ],
    );
  }

  /// The block's time-label cell; for admins it long-presses into the block
  /// editor (a small edit glyph hints at the gesture).
  Widget _labelCell(TimeBlock block, EdgeInsets cellPadding) {
    final label = Text(
      block.label,
      style: TextStyle(fontSize: fitWidth ? 11 : 12),
    );
    if (onLongPressBlock == null) {
      return Padding(padding: cellPadding, child: label);
    }
    return InkWell(
      onLongPress: () => onLongPressBlock!(block),
      child: Padding(
        padding: cellPadding,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(child: label),
            const SizedBox(width: 2),
            Builder(
              builder: (context) => Icon(
                Icons.edit_outlined,
                size: 12,
                color: Theme.of(context)
                    .colorScheme
                    .onSurfaceVariant
                    .withValues(alpha: 0.4),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _grid(BuildContext context, OpenDay day) {
    final scheme = Theme.of(context).colorScheme;
    // In fit-width mode the whole day must be visible at once: lanes flex to
    // share the available width (no horizontal scroll) and cell padding is
    // tightened so the narrow columns still fit their tiles. Otherwise the
    // grid keeps its fixed-width columns inside a horizontal scroller.
    final cellPadding = EdgeInsets.all(fitWidth ? 2 : 4);
    final labelWidth = fitWidth ? 52.0 : 92.0;

    // The day renders as Table CHUNKS of consecutive block rows interleaved
    // with full-width gap rows (Table has no colspan). Every chunk shares
    // identical columnWidths, so lanes stay aligned across chunks.
    Table buildChunk(List<TimeBlock> blocks, {required bool withHeader}) =>
        Table(
          defaultColumnWidth: fitWidth
              ? const FlexColumnWidth()
              : const FixedColumnWidth(84),
          columnWidths: {0: FixedColumnWidth(labelWidth)},
          border: TableBorder(
            horizontalInside: BorderSide(
              color: scheme.outlineVariant.withValues(alpha: 0.35),
            ),
          ),
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          children: [
            if (withHeader)
              TableRow(
                children: [
                  const SizedBox.shrink(),
                  for (var lane = 1; lane <= day.laneCount; lane++)
                    Padding(
                      padding: cellPadding,
                      child: Text(
                        'Dráha $lane',
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: fitWidth ? 12 : null,
                        ),
                      ),
                    ),
                ],
              ),
            for (final block in blocks)
              TableRow(
                children: [
                  _labelCell(block, cellPadding),
                  for (var lane = 1; lane <= day.laneCount; lane++)
                    Padding(
                      padding: cellPadding,
                      child: slotTileFor(
                        day: day,
                        block: block,
                        lane: lane,
                        size: SlotTileSize.compact,
                        me: me,
                        myCount: myCount,
                        settings: settings,
                        nameById: nameById,
                        clubColorById: clubColorById,
                        interactive: interactive,
                        onBook: onBook,
                        onCancel: onCancel,
                      ),
                    ),
                ],
              ),
          ],
        );

    final children = <Widget>[];
    var headerEmitted = false;
    var pendingBlocks = <TimeBlock>[];
    void flush() {
      if (pendingBlocks.isEmpty && headerEmitted) return;
      children.add(buildChunk(pendingBlocks, withHeader: !headerEmitted));
      headerEmitted = true;
      pendingBlocks = [];
    }

    for (final item in dayGridItems(day)) {
      switch (item) {
        case BlockItem(:final block):
          pendingBlocks.add(block);
        case EventItem(:final event):
          flush();
          children.add(GapEventBanner(event: event));
        case final EmptyGapItem gap:
          flush();
          children.add(EmptyGapRow(
            item: gap,
            onAdd: onAddBlockInGap == null
                ? null
                : () => onAddBlockInGap!(gap.start, gap.end),
          ));
      }
    }
    flush();

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
    if (fitWidth) return content;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: labelWidth + day.laneCount * 84,
        child: content,
      ),
    );
  }
}

/// Count of [playerId]'s live reservations that fall on exactly [date] —
/// the per-day dot count [DayChipStrip] renders (as opposed to
/// [activeReservationCount], which counts cumulatively from a date forward
/// for the active-reservations limit).
int _myLiveCountOn(List<Reservation> mine, String? playerId, Day date) {
  if (playerId == null) return 0;
  return mine
      .where((r) => r.playerId == playerId && r.isLive && r.date == date)
      .length;
}

/// Admin-only booking dialog: same confirmation as the plain player flow,
/// plus a player picker (defaults to the admin themself, labelled 'já').
/// Pops the chosen player's id, or null on cancel.
class _BookingDialog extends StatefulWidget {
  const _BookingDialog({
    required this.message,
    required this.me,
    required this.players,
  });

  final String message;
  final Profile me;
  final List<PlayerName> players;

  @override
  State<_BookingDialog> createState() => _BookingDialogState();
}

class _BookingDialogState extends State<_BookingDialog> {
  late String _playerId = widget.me.id;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rezervovat termín?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.message),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _playerId,
            decoration: const InputDecoration(labelText: 'Rezervovat pro'),
            items: [
              DropdownMenuItem(value: widget.me.id, child: const Text('já')),
              for (final p in widget.players)
                if (p.id != widget.me.id)
                  DropdownMenuItem(value: p.id, child: Text(p.displayName)),
            ],
            onChanged: (v) => setState(() => _playerId = v!),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Zrušit'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _playerId),
          child: const Text('Rezervovat'),
        ),
      ],
    );
  }
}
