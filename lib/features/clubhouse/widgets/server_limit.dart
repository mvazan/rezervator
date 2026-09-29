/// The length limit of the messages' text fields (0051), counted the way
/// the server counts it — see [serverLength].
library;

import 'package:flutter/material.dart';

import '../../../domain/messages.dart' show overLimit, serverLength;

/// [decoration] for a field whose [text] may hold at most [max] code
/// points: the counter under it counts code points („502/500“), and over
/// the limit the field and the counter turn to the error colour. The
/// field keeps its `maxLength` of [max] too — that stops typing at [max]
/// characters, which a multi-code-point emoji (👍🏽) can still exceed, so
/// the caller also holds back the send while [overLimit].
InputDecoration withServerLimit(
  BuildContext context,
  InputDecoration decoration,
  String text,
  int max,
) {
  final over = overLimit(text, max);
  return decoration.copyWith(
    counterText: '${serverLength(text)}/$max',
    counterStyle: over
        ? TextStyle(color: Theme.of(context).colorScheme.error)
        : null,
    // An error with no text of its own: the red outline marks the field,
    // the counter says by how much.
    error: over ? const SizedBox.shrink() : null,
  );
}
