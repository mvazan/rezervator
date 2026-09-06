# Moje tréninky — a second view beside the calendar (design)

Decided with the user on 2026-09-06.

## Goal

A player opens the app and sees what is coming for them: the trainings they
booked and the matches of their teams, one chronological list. The calendar
stays as it is. On a phone the two views are bottom tabs; on a tablet and the
desktop web they are a vertical rail on the left. Which view opens at launch
is a choice in the player's profile.

## Decisions (with the alternatives that lost)

- **The list's teams are a choice of their own**, on the profile, and the
  Google Calendar integration is left exactly as it is: its team choice
  (`google_calendar_links.match_teams`, picked in the calendar card after
  linking) keeps driving the sync alone. Showing matches in the app and
  syncing them to Google are two things a player manages separately. (An
  earlier draft moved the calendar's choice to the profile and shared it; the
  user simplified it to two independent lists.)
- **The view that opens at launch is a profile setting** („Po spuštění":
  Kalendář / Moje tréninky), stored on the profile like the own colour, so it
  follows the account across devices. Deriving it from the calendar link was
  dropped — the integration is not to be taken into account here.
- **Adaptive navigation**: `NavigationBar` (bottom tabs) when the screen's
  shortest side is under 600 px — a phone in either orientation — and a
  `NavigationRail` on the left otherwise. A segmented button in the calendar's
  header row was rejected (the row is full and the list has no week
  navigation); bottom tabs on a 1600 px desktop window were rejected.
- **The list can cancel** the player's own future reservation with the same
  confirm dialog the calendar uses; matches are read-only.
- **A tap changes the view for the rest of the session only**; the next
  launch opens the profile's choice again. Default of that choice for every
  existing profile: Kalendář — today's behaviour until a player opts in.

## Part 1 — data: two profile columns (migration 0029)

Nothing on the calendar side changes: `google_calendar_links.match_teams`,
`my_future_matches`, `match_calendar_followers`, `set_calendar_match_teams_for`
and the `calendar-manage` function stay as they are.

- `alter table profiles add column followed_teams text[] not null default
  '{}' check (coalesce(array_length(followed_teams, 1), 0) <= 20)` — the
  same count check the link column carries; names come from the sheet, which
  only offers the teams of imported matches, so no per-name rule. Comment:
  teams whose matches the player wants to see in Moje tréninky — display
  only; the calendar sync has its own choice on the link.
- `alter table profiles add column default_view text not null default
  'calendar' check (default_view in ('calendar', 'trainings'))`. Comment: the
  view the app opens at launch.
- `grant update (followed_teams, default_view) on profiles to authenticated` —
  the same direct-row pattern as `own_color` (0024): the player updates their
  own row under the existing profiles update policy, the checks validate. No
  RPC, no edge function.
- `supabase/schema.sql` regenerated; `docs/SCHEMA.md` profiles row and
  tenancy bullet updated; `SETUP.md` untouched.

### Client, part 1

- `Profile.followedTeams` (`json['followed_teams']`, default `[]`) and
  `Profile.defaultView` (`HomeView` enum: `calendar`, `trainings`; parsed from
  `json['default_view']`, unknown → `calendar`).
- `Api.setFollowedTeams(List<String>)` and `Api.setDefaultView(HomeView)` —
  `update profiles set … where id = uid`, like `Api.setOwnColor`.
- Profile screen, two additions between the colour card and the calendar
  card:
  - card **„Moje týmy"**: the summary line („Sleduješ: SKK Veverky Brno A, …"
    / „Zatím žádný tým") and a button „Vybrat týmy…" opening a checkbox sheet
    over `ourTeamsProvider` plus the already chosen names. Every tick saves
    at once. The sheet is the one the calendar card uses, extracted into
    `profile/widgets/team_picker_sheet.dart` and parameterised by
    `chosen` + `onChanged`, so both cards share it and the calendar card's
    behaviour does not change.
  - card **„Po spuštění"**: a `SegmentedButton<HomeView>` with „Kalendář" and
    „Moje tréninky"; selecting saves at once.
- `matchTeamsSummary` stays where it is and serves both cards.

## Part 2 — the list and the navigation

### `HomeShell`

- Holds `HomeView? _view`. While null, the first profile value
  (`myProfileProvider` — already loaded, the AuthGate does not show the shell
  without it) sets it to `profile.defaultView`. A tap on a destination sets
  `_view`; the profile setting is not consulted again until the next launch,
  even if the player changes it in the profile meanwhile.
- `MediaQuery.sizeOf(context).shortestSide < 600` → `Scaffold.bottomNavigationBar:
  NavigationBar` with destinations „Kalendář" (`Icons.calendar_month_outlined`
  / selected `Icons.calendar_month`) and „Moje tréninky"
  (`Icons.event_available_outlined` / `Icons.event_available`). Otherwise a
  `Row` of `NavigationRail` (labelType `all`, same destinations) + a vertical
  divider + the view.
- The offline and „prohlížíš cizí kuželnu" banners stay above the view in
  both layouts. The trailing icons (Správa for admins, Můj profil) are passed
  to both views exactly as they are passed to `WeekScreen` today.
- The kiosk shell is untouched.

### `MyTrainingsScreen` (`lib/features/schedule/my_trainings_screen.dart`)

- Header row: the title „Moje tréninky" on the left, the trailing icons on
  the right — the same one-line pattern as the calendar's week header, so the
  two views feel like siblings.
- Data (all live streams): `myActiveReservationsProvider`, `timeBlocksProvider`,
  `prioritySlotsProvider`, `myProfileProvider` (for `followedTeams`),
  `nowProvider` (for "today"; pinned in tests like `week_screen_test`).
- Pure builder in `lib/domain/upcoming.dart`:
  `List<UpcomingDay> upcomingTimeline({required List<Reservation> reservations,
  required List<TimeBlock> blocks, required List<PrioritySlot> slots,
  required List<String> teams, required Day today})` — keeps reservations that
  are live (`cancelledAt == null`) with `date >= today` and whose block still
  exists, and match slots (`type.isMatch`, `parentId == null`, `date >= today`,
  home or away team in `teams`); groups by date ascending; within a day sorts
  by start time (reservation: the block's `startsAt`; match: `startsAt`),
  matches after a reservation at the same start. `UpcomingDay(date, items)`,
  `UpcomingItem` is a sealed class: `UpcomingTraining(reservation, block)` and
  `UpcomingMatch(slot)`. A reservation whose block is gone (deleted template)
  is dropped — the calendar does not render it either.
- Rendering: per day a small header (`dayFull(date)`, „Dnes" / „Zítra" for
  today and tomorrow), then tiles.
  - Training tile: leading `Icons.sports_outlined` (the glyph the calendar
    card already uses for training-related rows), title
    `'${block.label} · Dráha ${lane}'`, subtitle none; tapping opens
    `confirmDialog(title: 'Zrušit rezervaci?', message: '${dayFull(date)} ·
    ${block.label} · Dráha ${lane}', confirmLabel: 'Zrušit rezervaci',
    cancelLabel: 'Zpět')` then `Api.cancelReservation(r.id)` via `tryAction`
    with `'Rezervace zrušena.'` — the calendar's own-reservation branch, no
    admin variants (the list only ever holds the player's own reservations).
  - Match tile: leading `Icons.emoji_events_outlined`, title
    `'${home} – ${away}'`, subtitle `'${startsAt}–${endsAt} · doma'` or
    `'… · venku'` followed by ` · ${description}` when non-empty (competition;
    away matches carry the venue there since the import). No tap.
- Empty states:
  - Nothing at all: centred „Zatím nic." / „Trénink si rezervuješ v
    kalendáři." with a `FilledButton.tonal` „Do kalendáře" that switches the
    shell to view 0 (callback `onOpenCalendar` passed by the shell).
  - Some items but `teams` empty: after the list a muted row „Zápasy svých
    týmů tu uvidíš, když si je vybereš v Můj profil → Moje týmy." (tapping
    opens the profile screen).
- Horizon: everything in the future. Reservations are bounded by the booking
  horizon anyway; matches run through the season.

### Changelog

One web-only entry (`Release(null, '<date>', …)`) per merged part, in the
tone of the existing ones: „Moje týmy" and „Po spuštění" in the profile; the
list and the tabs.

## Error handling

- Streams offline: `cachedRows` replays the last data; the list renders from
  the cache like the calendar and the offline banner is above it.
- Cancel fails (e.g. the slot already started, `past_slot`): the snack from
  `friendlyDbError`, the tile stays until the stream says otherwise.
- The `followed_teams` check rejects more than 20 teams; the sheet never
  offers more than the roster of imported matches, so this is a guard, not a
  flow. The snack shows `friendlyDbError`'s generic text.
- Saving offline: the snack, the checkbox / segment reverts to the stored
  value on the next profile stream tick.

## Testing

- **SQL** (`tenancy_rls.sql`): a player updates their own `followed_teams`
  and `default_view`; 21 teams and an unknown `default_view` value are
  rejected by the checks; another player's row is not updatable (existing
  policy); `anon` has no update on either column.
- **Dart unit** (`test/domain/upcoming_test.dart`): ordering across days and
  within a day, cancelled and past reservations dropped, missing block
  dropped, matches filtered by home OR away, away kept, empty input.
- **Widget**: `my_trainings_screen_test` (tiles and day headers, tap → confirm
  → `cancel_reservation` RPC in the mocked client, „Do kalendáře" callback,
  empty states, the teams hint); `home_shell_test` (the view at launch
  follows `profile.defaultView` — calendar and trainings; a tap sticks even
  when the profile setting changes afterwards; `NavigationBar` under 600 px,
  `NavigationRail` above; banners still shown); `profile_screen_test` („Moje
  týmy" card: summary, sheet opens, a tick PATCHes `followed_teams`; „Po
  spuštění" segment PATCHes `default_view`; the calendar card is unchanged).
- Existing suites stay green: 446 today.

## Delivery

Two pull requests, the second opened only after the first is merged:

1. `profile-teams-and-default-view` — migration 0029 + schema snapshot + SQL
   tests, `Profile.followedTeams` / `defaultView`, the shared team picker
   sheet, the „Moje týmy" and „Po spuštění" cards, docs.
2. `my-trainings-view` — `upcoming.dart` + tests, `MyTrainingsScreen` +
   tests, `HomeShell` navigation and default + tests, changelog entries.

Both deploy on merge (`deploy-backend` for the migration and the function,
`deploy-web` for the web); the phone gets it with the next build.
