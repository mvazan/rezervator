/// The team and club names as the app shows them (0080), for a plain widget.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart' show nameDisplayProvider;
import '../../domain/models.dart' show NameDisplay;

/// Builds [builder] with the names as the app shows them — the clubs'
/// nicknames ([nameDisplayProvider]) — and again when they change. Outside
/// a [ProviderScope] (a widget test of a plain widget) the names are as
/// stored ([NameDisplay.none]).
class ShownNames extends StatelessWidget {
  const ShownNames({super.key, required this.builder});

  final Widget Function(BuildContext context, NameDisplay names) builder;

  @override
  Widget build(BuildContext context) {
    try {
      ProviderScope.containerOf(context, listen: false);
    } on StateError {
      return builder(context, NameDisplay.none);
    }
    return Consumer(
      builder: (context, ref, _) =>
          builder(context, ref.watch(nameDisplayProvider)),
    );
  }
}

/// The names as the app shows them right now, read once — for a string a
/// widget hands on (a drag's label) rather than draws itself; as stored
/// outside a [ProviderScope].
NameDisplay shownNamesNow(BuildContext context) {
  try {
    return ProviderScope.containerOf(
      context,
      listen: false,
    ).read(nameDisplayProvider);
  } on StateError {
    return NameDisplay.none;
  }
}
