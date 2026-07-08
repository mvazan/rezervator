/// Full-screen adaptive letter-drill-down picker for the kiosk: narrows a
/// prefix one character at a time (via [nameIndex]) until few enough players
/// remain to list by name. Pops the chosen [PlayerName], or null on close.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../../domain/models.dart';
import '../../domain/name_index.dart';

/// How many candidates the picker is willing to show as name tiles at once
/// before falling back to next-letter prefix tiles.
const _capacity = 24;

Future<PlayerName?> showNamePicker(BuildContext context) {
  return showDialog<PlayerName>(
    context: context,
    builder: (_) => const NamePicker(),
  );
}

class NamePicker extends ConsumerStatefulWidget {
  const NamePicker({super.key});

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

    return Dialog.fullscreen(
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
              child: Text('$_prefix…',
                  style: Theme.of(context).textTheme.titleLarge),
            ),
          Expanded(
            child: SingleChildScrollView(
              child: switch (node) {
                PrefixesNode(:final prefixes, :final exactMatches) => Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      if (_prefix.isNotEmpty) _backTile(),
                      for (final p in exactMatches) _nameTile(p),
                      for (final prefix in prefixes) _prefixTile(prefix),
                    ],
                  ),
                NamesNode(:final players) => Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      if (_prefix.isNotEmpty) _backTile(),
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

  Widget _backTile() {
    final scheme = Theme.of(context).colorScheme;
    return _Tile(
      minWidth: 72,
      minHeight: 72,
      color: scheme.surfaceContainerHighest,
      onTap: _back,
      child: const Text('←', style: TextStyle(fontSize: 28)),
    );
  }

  Widget _prefixTile(String prefix) {
    final scheme = Theme.of(context).colorScheme;
    return _Tile(
      minWidth: 72,
      minHeight: 72,
      color: scheme.secondaryContainer,
      onTap: () => _drillInto(prefix),
      child: Text(
        prefix.substring(prefix.length - 1),
        style: TextStyle(fontSize: 28, color: scheme.onSecondaryContainer),
      ),
    );
  }

  Widget _nameTile(PlayerName player) {
    final scheme = Theme.of(context).colorScheme;
    return _Tile(
      minWidth: 200,
      minHeight: 64,
      color: scheme.primaryContainer,
      onTap: () => Navigator.pop(context, player),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Text(
          player.displayName,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 20, color: scheme.onPrimaryContainer),
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.minWidth,
    required this.minHeight,
    required this.color,
    required this.onTap,
    required this.child,
  });

  final double minWidth;
  final double minHeight;
  final Color color;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: minWidth, minHeight: minHeight),
          child: Center(child: child),
        ),
      ),
    );
  }
}
