import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/clock.dart';
import '../../data/providers.dart';
import '../../domain/labels.dart';
import '../../domain/models.dart';
import '../../domain/schedule.dart';
import '../../push/pending_link.dart';
import '../admin/admin_screen.dart';
import '../clubhouse/clubhouse_screen.dart';
import '../clubhouse/message_detail_screen.dart';
import '../clubhouse/notice_board_screen.dart';
import '../profile/profile_screen.dart';
import 'my_trainings_screen.dart';
import 'week_screen.dart';

/// The signed-in home: three views — Můj přehled, the calendar and Klubovna
/// — behind bottom tabs on a narrow screen and a rail on a wide one. Which
/// one opens at launch is the profile's choice (between the first two only
/// — Klubovna is a tab, not a launch target); a tap changes it for this run
/// only. All three views stay mounted (an IndexedStack, not a switch) so
/// paging the calendar forward and glancing at the list never loses the
/// week/day position — the hidden views keep rebuilding on the minute tick,
/// which is cheap enough to leave running offstage.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key, this.messageExists = Api.messageExists});

  /// Asks the server whether a deep-linked id still exists (RLS-scoped);
  /// throws when offline. Handed on to [MessageDetailScreen], and asked
  /// for a notice link whose loaded snapshot lacks the id.
  final Future<bool> Function(String id) messageExists;

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  /// Tapped in this run — wins over the profile's launch choice.
  HomeView? _chosen;

  /// The profile's choice as it stood when the shell first saw a profile.
  /// Captured once on purpose: changing it in Můj profil must not yank the
  /// running app to the other view.
  HomeView? _atLaunch;

  /// The body's own identity, so the LAYOUT may move it without the app
  /// starting over. Turning a phone sideways crosses the 600dp breakpoint:
  /// bottom tabs give way to a rail, and the body goes from being the
  /// SafeArea's child to sitting in a Row beside that rail. That is a
  /// different place in the tree, so without a key Flutter builds the whole
  /// thing afresh — and the calendar underneath loses the week the user had
  /// paged to, snapping back to the current one mid-rotation. With the key
  /// the subtree is MOVED, State and all.
  final _bodyKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    // fireImmediately: a link can already be waiting when HomeShell mounts
    // — a cold-start push tap (getInitialMessage) or a /zpravy/:id route
    // seeded before sign-in. Without it only warm taps would open. AuthGate
    // builds HomeShell only once the profile is loaded, so this is also
    // the spec's "once the profile is loaded".
    ref.listenManual(pendingLinkProvider, (_, next) {
      if (next != null) _openPendingLink(next);
    }, fireImmediately: true);
  }

  /// Opens a deep link (0051) once: a message on its detail screen, a
  /// notice on the board.
  void _openPendingLink(PendingLink link) {
    // May be called from initState (fireImmediately), where Riverpod allows
    // no provider write and the Navigator above HomeShell is not usable
    // yet: both the clear and the push wait for the end of the frame — and
    // a frame is asked for, since a warm tap may come while none is due.
    WidgetsBinding.instance
      ..addPostFrameCallback((_) => _consume(link))
      ..ensureVisualUpdate();
  }

  /// Clears [link] and opens it — unless it is no longer the pending one:
  /// a newer link replaced it (that one opens instead) or the same link
  /// was opened already. A push sent for another alley (a superadmin
  /// visiting elsewhere) is dropped without a word: this alley's RLS
  /// cannot see it, and „Zpráva už neexistuje.“ would be wrong.
  void _consume(PendingLink link) {
    if (!mounted || ref.read(pendingLinkProvider) != link) return;
    ref.read(pendingLinkProvider.notifier).clear();
    final tenantId = ref.read(myProfileProvider).value?.tenantId;
    if (link.tenantId != null && link.tenantId != tenantId) return;
    final navigator = Navigator.of(context);
    switch (link.kind) {
      case PendingLinkKind.message:
        navigator.push(MaterialPageRoute<void>(
            builder: (_) => MessageDetailScreen(link.id,
                messageExists: widget.messageExists)));
      case PendingLinkKind.notice:
        // Notices have no per-item page: the board is the detail, since
        // every player sees every notice there.
        navigator.push(MaterialPageRoute<void>(
            builder: (_) => const NoticeBoardScreen()));
        unawaited(_snackIfNoticeGone(link.id));
    }
  }

  /// Spec: an unknown or deleted id → a snack. A loaded snapshot without
  /// the id proves nothing by itself — cachedRows replays the cache first
  /// on a cold start, a warm tap finds the pre-background list, and the
  /// notice a push was sent for is usually newer than either — so, as
  /// `MessageDetailScreen._checkGone` does, the server is asked and only
  /// its "no" makes the snack. Anything unanswerable (no cache and no
  /// network, offline) stays silent: the board shows what it has.
  Future<void> _snackIfNoticeGone(String id) async {
    final messageExists = widget.messageExists;
    try {
      final messages = await ref.read(messagesProvider.future);
      if (messages.any((m) => m.id == id)) return;
      if (!mounted || await messageExists(id)) return;
    } catch (_) {
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Zpráva už neexistuje.')));
  }

  /// Superadmin's way back from a foreign kuželna (0015): switch the
  /// membership home and re-create every tenant-scoped stream.
  Future<void> _goHome(BuildContext context, String homeTenantId) async {
    final ok = await tryAction(
      context,
      () => Api.switchTenant(homeTenantId),
      success: 'Přepnuto zpět domů.',
      errorText: friendlyDbError,
    );
    if (!ok || !context.mounted) return;
    resetTenantScopedProviders(ref);
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(myProfileProvider).value;
    _atLaunch ??= profile?.defaultView;
    final view = _chosen ?? _atLaunch ?? HomeView.calendar;
    final offline = ref.watch(offlineProvider).value ?? false;
    // A superadmin switched into someone else's kuželna sees ONLY foreign
    // data — keep that on screen permanently, with one tap back home.
    final visiting = profile?.isVisiting ?? false;
    final visitingName = visiting
        ? ref.watch(tenantNameProvider(profile!.tenantId)).value
        : null;
    // No AppBar at all: both views draw the same top strip (HomeHeader) —
    // title (where the width allows), whatever the view puts in the middle
    // and these icons, on ONE line. Same strip on both, so the icons keep
    // their place when the tabs switch.
    final actions = [
      if (profile?.isAdmin ?? false)
        IconButton(
          icon: const Icon(Icons.admin_panel_settings_outlined),
          tooltip: 'Správa',
          visualDensity: VisualDensity.compact,
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const AdminScreen()),
          ),
        ),
      IconButton(
        icon: const Icon(Icons.account_circle_outlined),
        tooltip: 'Můj profil',
        visualDensity: VisualDensity.compact,
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const ProfileScreen()),
        ),
      ),
    ];

    // IndexedStack (not a switch swapping widgets in and out): every view
    // keeps its State — WeekScreen's week offset and day index survive a
    // glance at Můj přehled and back. children[i]'s index must line up
    // with HomeView's declaration order (see view.index below).
    final content = IndexedStack(
      index: view.index,
      children: [
        MyTrainingsScreen(
          trailing: actions,
          onOpenCalendar: () => setState(() => _chosen = HomeView.calendar),
        ),
        WeekScreen(trailing: actions),
        ClubhouseScreen(trailing: actions),
      ],
    );
    final body = Column(
      key: _bodyKey,
      children: [
        if (offline)
          MaterialBanner(
            content: const Text('Offline — poslední známý stav'),
            leading: const Icon(Icons.cloud_off_outlined),
            actions: const [SizedBox.shrink()],
          ),
        const _ReservationLimitBanner(),
        if (visiting)
          MaterialBanner(
            content: Text(
              visitingName == null
                  ? 'Prohlížíš cizí kuželnu'
                  : 'Prohlížíš kuželnu $visitingName',
            ),
            leading: const Icon(Icons.visibility_outlined),
            backgroundColor: Theme.of(context).colorScheme.tertiaryContainer,
            actions: [
              TextButton(
                onPressed: () => _goHome(context, profile!.homeTenantId),
                child: const Text('Zpět domů'),
              ),
            ],
          ),
        Expanded(child: content),
      ],
    );

    // Material's own adaptive-navigation breakpoint: below 600dp of WIDTH,
    // bottom tabs; at or above it, a rail on the left — same three
    // destinations either way. Width, not the shorter side, on purpose: a
    // phone turned to landscape has plenty of width but a short height, and
    // a bottom bar stretched across that width leaves its destinations
    // stranded far apart, which is exactly the case this breakpoint exists
    // to catch — a rail with the same 3 destinations is the compact fit.
    final compact = MediaQuery.sizeOf(context).width < 600;
    void select(int index) => setState(() => _chosen = HomeView.values[index]);

    // A back gesture/button away from the calendar returns to it instead of
    // popping the route (there is nothing to pop to from the home screen
    // anyway). The target is the CALENDAR, not whichever tab comes first:
    // the calendar is what the app is for and what a fresh profile opens
    // on, and that did not change when Můj přehled moved to the left.
    return PopScope(
      canPop: view == HomeView.calendar,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        setState(() => _chosen = HomeView.calendar);
      },
      child: Scaffold(
        body: SafeArea(
          child: compact
              ? body
              : Row(
                  children: [
                    NavigationRail(
                      selectedIndex: view.index,
                      onDestinationSelected: select,
                      labelType: NavigationRailLabelType.all,
                      // The three destinations need ~220dp of height.
                      // Nothing guarantees that once the rail keys off
                      // width alone, so let them scroll rather than
                      // overflow.
                      scrollable: true,
                      destinations: const [
                        NavigationRailDestination(
                          icon: Icon(Icons.event_available_outlined),
                          selectedIcon: Icon(Icons.event_available),
                          label: Text('Můj přehled'),
                        ),
                        NavigationRailDestination(
                          icon: Icon(Icons.calendar_month_outlined),
                          selectedIcon: Icon(Icons.calendar_month),
                          label: Text('Kalendář'),
                        ),
                        NavigationRailDestination(
                          icon: _KlubovnaIcon(selected: false),
                          selectedIcon: _KlubovnaIcon(selected: true),
                          label: Text('Klubovna'),
                        ),
                      ],
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(child: body),
                  ],
                ),
        ),
        bottomNavigationBar: compact
            ? NavigationBar(
                selectedIndex: view.index,
                onDestinationSelected: select,
                destinations: const [
                  NavigationDestination(
                    icon: Icon(Icons.event_available_outlined),
                    selectedIcon: Icon(Icons.event_available),
                    label: 'Můj přehled',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.calendar_month_outlined),
                    selectedIcon: Icon(Icons.calendar_month),
                    label: 'Kalendář',
                  ),
                  NavigationDestination(
                    icon: _KlubovnaIcon(selected: false),
                    selectedIcon: _KlubovnaIcon(selected: true),
                    label: 'Klubovna',
                  ),
                ],
              )
            : null,
      ),
    );
  }
}

/// The Klubovna destination's icon, with a dot while a message or notice
/// is unread (0051) — the hub inside shows the counts. A leaf of its own,
/// like [_ReservationLimitBanner]: an unread change repaints this icon, not
/// the whole shell, and the destination lists stay const.
class _KlubovnaIcon extends ConsumerWidget {
  const _KlubovnaIcon({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dot = ref.watch(
      unreadCountsProvider.select((c) => c.messages + c.notices > 0),
    );
    final icon = Icon(selected ? Icons.groups : Icons.groups_outlined);
    return dot ? Badge(smallSize: 8, child: icon) : icon;
  }
}

/// Why no ＋ shows up anywhere: at the alley's cap on live reservations both
/// views simply stop offering free slots, which without a word reads as a
/// broken screen. A leaf of its own, so the minute tick it needs to know
/// what "future" means repaints this strip and not the whole shell; the
/// count and the cap are already streamed for the calendar itself, so it
/// costs no new subscription either.
class _ReservationLimitBanner extends ConsumerWidget {
  const _ReservationLimitBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(myProfileProvider).value;
    final settings = ref.watch(settingsProvider).value;
    if (profile == null || settings == null) return const SizedBox.shrink();
    // An ADMIN is never stopped by the cap — create_reservation skips the
    // limit for them — so telling them "another one will go once this one
    // is over" would simply be false. What they get instead is a warning in
    // the booking dialog, about whoever they are booking for.
    if (profile.isAdmin) return const SizedBox.shrink();
    final now = ref.watch(nowProvider).value ?? DateTime.now();
    final count = activeReservationCount(
      ref.watch(myActiveReservationsProvider).value ?? const [],
      profile.id,
      Day.fromDateTime(now),
    );
    if (!atReservationLimit(count, settings)) return const SizedBox.shrink();
    // On canteen duty (0050) the ＋ stays — for booking the others; in a
    // group (0044) it stays too — for booking the mates. The duty's is the
    // wider promise, so it wins.
    final onDuty = ref.watch(myDutyProvider.select((d) => d.onDuty));
    final hasMates = ref.watch(
      myGroupProvider.select((g) => g.matesOf(profile.id).isNotEmpty),
    );
    return MaterialBanner(
      content: Text(
        onDuty
            ? reservationLimitDutyBanner
            : hasMates
                ? reservationLimitGroupBanner
                : reservationLimitNote(settings.maxActiveReservations),
      ),
      leading: const Icon(Icons.info_outline),
      actions: const [SizedBox.shrink()],
    );
  }
}
