import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../config.dart';
import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';
import 'changelog.dart';
import 'widgets/reservation_color_picker.dart';
import 'widgets/appearance_card.dart';
import 'widgets/calendar_link_card.dart';
import 'widgets/contact_card.dart';
import 'widgets/my_group_card.dart';
import 'widgets/my_teams_card.dart';
import 'widgets/reminders_sheet.dart';

/// App version/build, read once from the platform — drives the version line
/// at the bottom of the profile screen.
final _packageInfoProvider =
    FutureProvider((_) => PackageInfo.fromPlatform());

/// Self-service profile screen: every signed-in user can see their display
/// name/club (set at registration by an admin) and edit their own board
/// nick. Structured so future editable fields slot in as more list tiles.
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({
    super.key,
    this.signOut = Api.signOut,
    this.setOwnColor = Api.setOwnColor,
    this.setFollowedTeams = Api.setFollowedTeams,
    this.setCalendarTeams = Api.setCalendarTeams,
    this.setNotifyBefore = Api.setNotifyBefore,
    this.setTeamColors = Api.setTeamColors,
    this.setDefaultView = Api.setDefaultView,
    this.updateMyContact = Api.updateMyContact,
    this.loadRegnumCandidates = Api.regnumCandidates,
    this.confirmRegnum = Api.confirmRegnum,
  });

  /// Injectable for widget tests (the Api ones need a live Supabase client).
  final Future<void> Function() signOut;
  final Future<void> Function(int color) setOwnColor;
  final Future<void> Function(List<String> teams) setFollowedTeams;
  final Future<void> Function(List<CalendarTeam> teams) setCalendarTeams;
  final Future<void> Function(List<int> minutes) setNotifyBefore;
  final Future<void> Function(Map<String, int?> colors) setTeamColors;
  final Future<void> Function(HomeView view) setDefaultView;
  final Future<void> Function({String? phone, bool? showEmail, bool? showPhone})
      updateMyContact;
  final Future<List<RegnumCandidate>> Function() loadRegnumCandidates;
  final Future<String> Function(RegnumCandidate candidate) confirmRegnum;

  Future<void> _editNick(BuildContext context, String currentNick) async {
    final input = await promptText(
      context,
      title: 'Přezdívka na tabuli',
      message: 'Krátké jméno do rezervace a na tabuli v kuželně. Necháš-li '
          'ji prázdnou, ukáže se tvoje celé jméno.',
      hint: 'např. Tom P.',
      initial: currentNick,
      confirmLabel: 'Uložit',
    );
    if (input == null || !context.mounted) return;
    await tryAction(
      context,
      () => Api.setNick(currentUserId!, input),
      success: 'Uloženo.',
      errorText: friendlyDbError,
    );
  }

  /// „Doplnit reg. č.“: the people of the player's name in the ČKA register,
  /// and he says which one is he (0059). The server fills the number in by
  /// itself only when his club leaves one person; a namesake — a parent or a
  /// child of the club — needs this.
  Future<void> _pickRegnum(BuildContext context) async {
    List<RegnumCandidate>? candidates;
    final loaded = await tryAction(
      context,
      () async => candidates = await loadRegnumCandidates(),
      errorText: friendlyDbError,
    );
    if (!loaded || !context.mounted) return;
    if (candidates!.isEmpty) {
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Registrační číslo'),
          content: const Text(
            'V evidenci ČKA nikdo s tvým jménem není, nebo už číslo máš. '
            'Případně ti jméno opraví správce.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Zavřít'),
            ),
          ],
        ),
      );
      return;
    }
    final picked = await showModalBottomSheet<RegnumCandidate>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => RegnumCandidatesSheet(candidates: candidates!),
    );
    if (picked == null || !context.mounted) return;
    await tryAction(
      context,
      () => confirmRegnum(picked),
      success: 'Registrační číslo uloženo.',
      errorText: friendlyDbError,
    );
  }

  Future<void> _logout(BuildContext context) async {
    final ok = await confirmDialog(
      context,
      title: 'Odhlásit se',
      message: 'Opravdu se chceš odhlásit?',
      confirmLabel: 'Odhlásit se',
    );
    if (!ok || !context.mounted) return;
    final done = await tryAction(context, signOut, errorText: friendlyDbError);
    // This screen sits pushed above AuthGate; the gate swaps its own route to
    // the login screen, but a pushed route would stay on top showing an
    // eternal spinner (profile is null once the session is gone).
    if (done && context.mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(myProfileProvider).value;
    final clubs = ref.watch(clubsProvider).value ?? const <Club>[];
    // The registration number is looked up in the ČKA register by name and
    // club, once; the profile row updates when the server found it.
    if (profile != null && profile.regnum == null) {
      ref.watch(profileRegnumsProvider);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Můj profil')),
      body: profile == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: padWithSystemInset(context, const EdgeInsets.all(12)),
              children: [
                Card(
                  child: Column(
                    children: [
                      ListTile(
                        title: const Text('Jméno'),
                        subtitle: Text(profile.displayName),
                        // The ČKA register's number, once found (0057).
                        trailing: profile.regnum == null
                            ? TextButton(
                                onPressed: () => _pickRegnum(context),
                                child: const Text('Doplnit reg. č.'),
                              )
                            : Text(
                                'reg. č. ${profile.regnum}',
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                      ),
                      ListTile(
                        title: const Text('E-mail'),
                        subtitle: Text(profile.email),
                      ),
                      ContactPhoneTile(
                        profile: profile,
                        updateMyContact: updateMyContact,
                      ),
                      ListTile(
                        title: const Text('Oddíl'),
                        subtitle: Text(
                          clubNameOf(profile.clubId, clubs).isEmpty
                              ? '—'
                              : clubNameOf(profile.clubId, clubs),
                        ),
                      ),
                      // What Klubovna → Kontakty shows of the e-mail and
                      // the phone above (0048).
                      ContactVisibilityTiles(
                        profile: profile,
                        updateMyContact: updateMyContact,
                      ),
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'Jméno a oddíl nastavuje správce; registrační číslo '
                            'se hledá v evidenci ČKA podle jména a oddílu; '
                            'e-mail je ten, kterým se přihlašuješ.',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                // Tabule: the two things that say how the player appears in
                // the schedule — the short name their cells carry (and the
                // kiosk board shows), and the colour those cells wear. They
                // were two cards saying two halves of one answer.
                Card(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const ListTile(
                        title: Text('Tabule'),
                        subtitle: Text('Jak vypadají tvoje rezervace.'),
                      ),
                      ListTile(
                        title: const Text('Přezdívka'),
                        subtitle: Text(
                          profile.nick.isEmpty ? 'nenastavena' : profile.nick,
                        ),
                        trailing: TextButton(
                          onPressed: () => _editNick(context, profile.nick),
                          child: const Text('Upravit'),
                        ),
                      ),
                      // Own colour for own reservations (0024): the board is
                      // read by club colour, this lets the player's own cells
                      // stand out in their own view; everyone else keeps
                      // seeing the club.
                      const ListTile(
                        title: Text('Barva mých rezervací'),
                        subtitle: Text(
                          'Jen pro tebe — ostatní vidí barvu oddílu.',
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        child: ReservationColorPicker(
                          selected: profile.ownColor,
                          onChanged: (color) => tryAction(
                            context,
                            () => setOwnColor(color),
                            errorText: friendlyDbError,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                // What opens at launch (0029). A tab tap changes the view for
                // one run; this is what the next launch reads.
                Card(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const ListTile(
                        title: Text('Po spuštění'),
                        subtitle: Text(
                          'Co appka otevře jako první. Přepnutí dole platí '
                          'do jejího zavření.',
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        child: SegmentedButton<HomeView>(
                          // Same order as the tabs downstairs, so the two
                          // read as the same views.
                          segments: const [
                            ButtonSegment(
                              value: HomeView.trainings,
                              label: Text('Můj přehled'),
                            ),
                            ButtonSegment(
                              value: HomeView.calendar,
                              label: Text('Kalendář'),
                            ),
                            ButtonSegment(
                              value: HomeView.clubhouse,
                              label: Text('Klubovna'),
                            ),
                          ],
                          selected: {profile.defaultView},
                          onSelectionChanged: (chosen) => tryAction(
                            context,
                            () => setDefaultView(chosen.first),
                            errorText: friendlyDbError,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                MyTeamsCard(
                  profile: profile,
                  setFollowedTeams: setFollowedTeams,
                  setCalendarTeams: setCalendarTeams,
                  setTeamColors: setTeamColors,
                ),
                const SizedBox(height: 16),
                MyGroupCard(meId: profile.id),
                const SizedBox(height: 16),
                // Reminders of one's own (0040): the app says what is
                // coming, for the player who has no Google calendar — or
                // who wants both, which is nobody's business but theirs.
                // Not gated on the app being installed: the reminder
                // reaches them the way every other message does, push with
                // a phone in their pocket and e-mail without one.
                Card(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ListTile(
                        leading: const Icon(Icons.notifications_none_outlined),
                        // Whose reminders these are, said in the title: the
                        // Google calendar has its own set a card below, and
                        // a player who runs both would otherwise have two
                        // rows called Připomínky and no way to tell them
                        // apart.
                        title: const Text('Připomínky z appky'),
                        isThreeLine: true,
                        subtitle: Text(
                          'Před tréninkem a zápasem — push do mobilu, jinak '
                          'e-mailem.\n'
                          '${remindersSummary(profile.notifyBefore)}',
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: FilledButton.tonal(
                            onPressed: () => showRemindersSheet(
                              context,
                              title: 'Připomínky z appky',
                              emptyCopy: 'Před tréninkem ani zápasem se nic '
                                  'neozve.',
                              minutesOf: (sheetRef) =>
                                  sheetRef.watch(myProfileProvider).value
                                      ?.notifyBefore ??
                                  const [],
                              onChanged: setNotifyBefore,
                            ),
                            child: const Text('Nastavit…'),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                // Hidden without a Google client ID baked in, and for the
                // Play-review demo account (a shared account has no calendar
                // of its own to link).
                if (ref.watch(calendarAvailableProvider) &&
                    !AppConfig.isDemoAccount(profile.email)) ...[
                  const CalendarLinkCard(),
                  const SizedBox(height: 16),
                ],
                // Appearance (theme, text size) last: it is about the app
                // rather than about the player's kuželky, and nothing above
                // it depends on it.
                const AppearanceCard(),
                const SizedBox(height: 16),
                Card(
                  child: ListTile(
                    leading: Icon(
                      Icons.logout,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    title: Text(
                      'Odhlásit se',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                    onTap: () => _logout(context),
                  ),
                ),
                const SizedBox(height: 24),
                if (ref.watch(_packageInfoProvider).value case final info?)
                  Center(
                    child: InkWell(
                      onTap: () => showChangelog(context),
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(
                          'verze ${info.version} (build ${info.buildNumber})'
                          ' · co je nového?',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: Theme.of(context).colorScheme.outline,
                              ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

/// „Která osoba jsi ty?“ (0059): the register's people of the player's name,
/// by club and age; he picks himself and confirms. The register's number is
/// not shown — it goes to his profile once he has chosen.
class RegnumCandidatesSheet extends StatefulWidget {
  const RegnumCandidatesSheet({super.key, required this.candidates});

  final List<RegnumCandidate> candidates;

  @override
  State<RegnumCandidatesSheet> createState() => _RegnumCandidatesSheetState();
}

class _RegnumCandidatesSheetState extends State<RegnumCandidatesSheet> {
  RegnumCandidate? _picked;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Která osoba jsi ty?', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'V evidenci ČKA je víc lidí s tvým jménem. Poznáš se podle '
              'klubu a věku.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Flexible(
              child: RadioGroup<RegnumCandidate>(
                groupValue: _picked,
                onChanged: (c) => setState(() => _picked = c),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final c in widget.candidates)
                      RadioListTile<RegnumCandidate>(
                        value: c,
                        title: Text(c.club.isEmpty ? '—' : c.club),
                        subtitle: Text(c.age == null ? 'věk neuveden' : '${c.age} let'),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: _picked == null
                    ? null
                    : () => Navigator.of(context).pop(_picked),
                child: const Text('To jsem já'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
