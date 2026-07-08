/// Minimal CSV writer tuned for Czech Excel: UTF-8 BOM + semicolons.
library;

String toCsv(List<List<String>> rows) {
  String field(String value) {
    if (value.contains(';') ||
        value.contains('"') ||
        value.contains('\n') ||
        value.contains('\r')) {
      return '"${value.replaceAll('"', '""')}"';
    }
    return value;
  }

  return '﻿${rows.map((r) => r.map(field).join(';')).join('\r\n')}';
}
