/// Full-screen adaptive letter-drill-down picker for the kiosk: narrows a
/// prefix one character at a time (via [nameIndex]) until few enough players
/// remain to list by name. Pops the chosen [PlayerName], or null on close.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';
import '../../domain/name_index.dart';

/// How many candidates the picker is willing to show as name tiles at once
/// before falling back to next-letter prefix tiles.
const _capacity = 24;

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
    // _backTile, _prefixTile) must use a BuildContext that's a *descendant*
    // of this Theme, not this State's own context — the State's context sits
    // above the widget tree this build() method returns, so Theme.of(context)
    // calls made directly with it would still resolve to the stale ambient
    // theme even though everything actually painted on screen (Dialog's
    // background, _Tile's own Theme.of lookups) is correctly dark.
    return Theme(
      data: buildTheme(widget.brightness),
      child: Builder(
        builder: (context) => Dialog.fullscreen(
          child: SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Kdo si rezervuje?',
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                      ),
                      IconButton(
                        iconSize: 32,
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
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_prefix.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                '$_prefix…',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
          Expanded(
            child: SingleChildScrollView(
              child: switch (node) {
                PrefixesNode(:final prefixes, :final exactMatches) => Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    if (_prefix.isNotEmpty) _backTile(context),
                    for (final p in exactMatches) _nameTile(p),
                    for (final prefix in prefixes)
                      _prefixTile(context, prefix),
                  ],
                ),
                NamesNode(:final players) => Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    if (_prefix.isNotEmpty) _backTile(context),
                    for (final p in players) _nameTile(p),
                  ],
                ),
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _backTile(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _Tile(
      minWidth: 72,
      minHeight: 72,
      outlineColor: scheme.primary.withValues(alpha: 0.45),
      onTap: _back,
      child: Text('←', style: TextStyle(fontSize: 28, color: scheme.onSurface)),
    );
  }

  Widget _prefixTile(BuildContext context, String prefix) {
    final scheme = Theme.of(context).colorScheme;
    return _Tile(
      minWidth: 72,
      minHeight: 72,
      outlineColor: scheme.primary.withValues(alpha: 0.45),
      onTap: () => _drillInto(prefix),
      child: Text(
        prefix.substring(prefix.length - 1),
        style: TextStyle(fontSize: 28, color: scheme.onSurface),
      ),
    );
  }

  Widget _nameTile(PlayerName player) {
    // The name tile IS the selection action (tapping it immediately pops
    // the picker with this player) — it gets the indigo→cyan gradient fill
    // per spec, vs. the plain indigo-outline nav tiles above.
    return _Tile(
      minWidth: 200,
      minHeight: 64,
      gradient: true,
      onTap: () => Navigator.pop(context, player),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Text(
          player.displayName,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.minWidth,
    required this.minHeight,
    required this.onTap,
    required this.child,
    this.outlineColor,
    this.gradient = false,
  });

  final double minWidth;
  final double minHeight;
  final VoidCallback onTap;
  final Widget child;

  /// Dark tile look: transparent fill, indigo outline. Used by the
  /// navigation tiles (back / next-letter prefix).
  final Color? outlineColor;

  /// Selection tile look: indigo→cyan gradient fill, no outline. Used by
  /// name tiles — the actual pick.
  final bool gradient;

  static const _gradientColors = [Color(0xFF6366F1), Color(0xFF22D3EE)];

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(16);
    final scheme = Theme.of(context).colorScheme;
    return Ink(
      decoration: BoxDecoration(
        borderRadius: radius,
        gradient: gradient
            ? const LinearGradient(colors: _gradientColors)
            : null,
        color: gradient ? null : scheme.surfaceContainerHigh,
        border: outlineColor != null
            ? Border.all(color: outlineColor!, width: 1.5)
            : null,
      ),
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: minWidth, minHeight: minHeight),
          child: Center(child: child),
        ),
      ),
    );
  }
}
