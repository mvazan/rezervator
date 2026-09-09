/// Full-screen adaptive letter-drill-down picker for the kiosk: narrows a
/// prefix one character at a time (via [nameIndex]) until few enough players
/// remain to list by name. Pops the chosen [PlayerName], or null on close.
///
/// Layout and colour are the point of this screen, not decoration: it runs
/// on a tablet on the wall and is tapped by people standing in front of it,
/// so letters are big squares laid out in a real grid and names are wide
/// buttons in as many columns as the screen affords. (Both used to be ONE
/// FULL-WIDTH ROW EACH — a `Center` inside a `Wrap` child expands to the
/// loose constraints it is given — which turned a 30-name roster into a
/// scroll marathon and left most of a 1920px screen empty.) A name tile
/// carries its player's CLUB colour: the same colour that player's
/// reservations already have on the board behind this dialog, so the tile
/// is recognised before it is read.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';
import '../../domain/name_index.dart';
import '../../domain/palette.dart';

/// How many candidates the picker is willing to show as name tiles at once
/// before falling back to next-letter prefix tiles.
const _capacity = 24;

/// Touch targets for a wall-mounted tablet, well past the 48dp minimum: a
/// letter is a square you can hit without aiming, a name a wide button.
const _letterTile = 116.0;
const _nameTileHeight = 88.0;

/// The narrowest a name tile may get before the grid drops a column — wide
/// enough for a long Czech full name at 22px without ellipsis.
const _nameTileMinWidth = 300.0;

/// More than four columns would put the names of a wide screen so far apart
/// that scanning them beats reading them.
const _maxNameColumns = 4;

const _tileGap = 12.0;

Future<PlayerName?> showNamePicker(
  BuildContext context, {
  Brightness brightness = Brightness.dark,
}) {
  return showDialog<PlayerName>(
    context: context,
    builder: (_) => NamePicker(brightness: brightness),
  );
}

class NamePicker extends ConsumerStatefulWidget {
  const NamePicker({super.key, this.brightness = Brightness.dark});

  /// The kiosk theme brightness (admin-configurable). The picker is opened
  /// from the shell's State context, which sits above the kiosk Theme wrap,
  /// so it must re-apply the theme itself — see build().
  final Brightness brightness;

  @override
  ConsumerState<NamePicker> createState() => _NamePickerState();
}

class _NamePickerState extends ConsumerState<NamePicker> {
  String _prefix = '';

  @override
  void initState() {
    super.initState();
    // A stale roster (e.g. someone approved since the app started, or since
    // the kiosk's last idle reset) must not hide a player who just walked
    // in — re-read on every picker open.
    Future.microtask(() => ref.invalidate(playersProvider));
  }

  void _drillInto(String prefix) => setState(() => _prefix = prefix);

  void _back() =>
      setState(() => _prefix = _prefix.substring(0, _prefix.length - 1));

  @override
  Widget build(BuildContext context) {
    final players = ref.watch(playersProvider);

    // The kiosk follows the admin-configured theme (spec §4), but
    // showNamePicker is called with the kiosk shell's own State context —
    // which sits *above* the kiosk Theme wrap in kiosk_shell.dart's build(),
    // not below it — so showDialog's route, and this dialog's content, would
    // otherwise inherit whatever theme is ambient at the call site. Wrapping
    // the whole dialog content here — including Dialog.fullscreen itself,
    // whose own background color also resolves Theme.of(context) — re-applies
    // the kiosk brightness passed in by the shell, regardless of which
    // context it was opened from.
    //
    // The Builder below matters, not just the Theme: every Theme.of(context)
    // call in this file that builds a color/text style (the header, _body,
    // the tiles) must use a BuildContext that's a *descendant* of this
    // Theme, not this State's own context — the State's context sits above
    // the widget tree this build() method returns, so Theme.of(context)
    // calls made directly with it would still resolve to the stale ambient
    // theme even though everything actually painted on screen (Dialog's
    // background, the tiles' own Theme.of lookups) is correctly dark.
    return Theme(
      data: buildTheme(widget.brightness),
      child: Builder(
        builder: (context) => Dialog.fullscreen(
          child: SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 16, 12, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Kdo si rezervuje?',
                          style: Theme.of(context).textTheme.headlineMedium,
                        ),
                      ),
                      IconButton(
                        iconSize: 32,
                        tooltip: 'Zavřít',
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: players.when(
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                    error: (e, _) => Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('Nepodařilo se načíst hráče.'),
                          const SizedBox(height: 12),
                          OutlinedButton(
                            onPressed: () => ref.invalidate(playersProvider),
                            child: const Text('Zkusit znovu'),
                          ),
                        ],
                      ),
                    ),
                    data: (allPlayers) => _body(context, allPlayers),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, List<PlayerName> allPlayers) {
    final node = nameIndex(
      players: allPlayers,
      prefix: _prefix,
      capacity: _capacity,
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Going back is navigation, not a choice among the letters — it
          // gets its own row above the grid instead of a tile inside it,
          // where it competed with the letters for the eye and moved every
          // time the letter count changed.
          if (_prefix.isNotEmpty) _breadcrumb(context),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                // A short grid (nine first letters, say) parked in a strip
                // along the top of a wall tablet looks like a loading state
                // and puts the targets at the far edge of reach; centring it
                // in the space it has costs nothing when the list is long
                // enough to scroll, because then minHeight is already met.
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Center(
                    child: switch (node) {
                      PrefixesNode(:final prefixes, :final exactMatches) =>
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Someone whose whole name IS the prefix cannot
                            // be narrowed further — they are a choice, not a
                            // step.
                            if (exactMatches.isNotEmpty) ...[
                              _nameGrid(
                                  context, exactMatches, constraints.maxWidth),
                              const SizedBox(height: 24),
                            ],
                            Wrap(
                              spacing: _tileGap,
                              runSpacing: _tileGap,
                              alignment: WrapAlignment.center,
                              children: [
                                for (final prefix in prefixes)
                                  _LetterTile(
                                    letter:
                                        prefix.substring(prefix.length - 1),
                                    onTap: () => _drillInto(prefix),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      NamesNode(:final players) =>
                        _nameGrid(context, players, constraints.maxWidth),
                    },
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _breadcrumb(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Row(
          children: [
            SizedBox(
              height: 64,
              child: FilledButton.tonalIcon(
                onPressed: _back,
                iconAlignment: IconAlignment.start,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  textStyle:
                      const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                ),
                icon: const Icon(Icons.arrow_back, size: 26),
                label: const Text('Zpět'),
              ),
            ),
            const SizedBox(width: 20),
            Text(
              '$_prefix…',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
          ],
        ),
      );

  /// Name tiles in as many columns as [width] affords, each column an equal
  /// share of it — a ragged Wrap of content-sized buttons reads as a pile,
  /// a grid as a list you can scan down.
  Widget _nameGrid(BuildContext context, List<PlayerName> players, double width) {
    final columns =
        (width / _nameTileMinWidth).floor().clamp(1, _maxNameColumns);
    final tileWidth = (width - (columns - 1) * _tileGap) / columns;
    return Wrap(
      spacing: _tileGap,
      runSpacing: _tileGap,
      children: [
        for (final player in players)
          SizedBox(
            width: tileWidth,
            child: _NameTile(
              player: player,
              onTap: () => Navigator.pop(context, player),
            ),
          ),
      ],
    );
  }
}

/// One step of the drill-down: a big neutral square with a single letter.
/// Deliberately colourless — a letter belongs to no club.
class _LetterTile extends StatelessWidget {
  const _LetterTile({required this.letter, required this.onTap});

  final String letter;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _Tile(
      width: _letterTile,
      height: _letterTile,
      background: scheme.surfaceContainerHigh,
      // The fill itself is only ~1.5:1 above the page, so the OUTLINE is
      // what makes the target visible; scheme.outline measures 5.92:1 dark
      // / 4.48:1 light against it (outlineVariant would be 1.8 / 1.7 — see
      // test/features/name_picker_contrast_test.dart).
      border: scheme.outline,
      onTap: onTap,
      child: Text(
        letter,
        style: TextStyle(
          fontSize: 44,
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
        ),
      ),
    );
  }
}

/// The pick itself: the player's name on their CLUB's colour — the same
/// pair the board tints their reservations with, so a player looking for
/// themselves can go by colour first and text second.
class _NameTile extends StatelessWidget {
  const _NameTile({required this.player, required this.onTap});

  final PlayerName player;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // The palette's own background/foreground pair (or the derived shades
    // of a hand-picked colour); a player with no club gets the neutral
    // surface, like an unclubbed cell on the board.
    final club = ClubColors.of(player.clubColor, scheme.brightness);
    final bg = club?.$1 ?? scheme.surfaceContainerHigh;
    final fg = club?.$2 ?? scheme.onSurface;
    return _Tile(
      height: _nameTileHeight,
      background: bg,
      // A club fill sits barely 1.1–2.2:1 above the kiosk page — nowhere
      // near the 3:1 WCAG asks of a control's boundary — so the tile is
      // outlined in its own TEXT colour, which measures 4.25:1 at worst
      // (a hand-picked hue in the light theme) and 6.85:1 across the
      // palette. Clubless tiles borrow scheme.outline for the same reason.
      border: club == null ? scheme.outline : fg,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text(
          // The player's own nick, when they set one — the same label their
          // reservations wear on the board behind this dialog. The full name
          // still appears in the bar once they are picked, which is where a
          // nick two people share gets caught.
          player.boardName,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          // 22px bold is "large text" to WCAG (≥18.66px bold), whose bar is
          // 3:1 — which the worst hand-picked club colour clears at 4.06:1
          // and the palette at 4.65:1. A smaller second line (the club's
          // name, say) would be normal text at those same ratios and would
          // NOT clear its 4.5:1 bar, which is why the tile carries only
          // the name.
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            color: fg,
          ),
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.height,
    required this.background,
    required this.border,
    required this.onTap,
    required this.child,
    this.width,
  });

  /// Null = fill the width the parent gives (the name grid's column).
  final double? width;
  final double height;
  final Color background;
  final Color border;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(16);
    return SizedBox(
      width: width,
      height: height,
      child: Ink(
        decoration: BoxDecoration(
          borderRadius: radius,
          color: background,
          border: Border.all(color: border, width: 2),
        ),
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: Center(child: child),
        ),
      ),
    );
  }
}
