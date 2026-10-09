import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

String? _last;

/// Sets the page's background (`<body>`) to [color], once per colour.
void setPageBackground(Color color) {
  final hex =
      '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
  if (hex == _last) return;
  _last = hex;
  web.document.body?.style.backgroundColor = hex;
}
