import 'dart:math';

String normalizeRelativePath(String value) {
  final parts = value.replaceAll('\\', '/').split('/');
  final clean = <String>[];
  for (final part in parts) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      throw ArgumentError('Path traversal is not allowed.');
    }
    clean.add(part);
  }
  return clean.join('/');
}

String joinRelativePath(String parent, String child) {
  final normalizedParent = normalizeRelativePath(parent);
  final normalizedChild = normalizeRelativePath(child);
  return [
    if (normalizedParent.isNotEmpty) normalizedParent,
    normalizedChild,
  ].join('/');
}

String uniqueSuffix() {
  final random = Random.secure().nextInt(1 << 32).toRadixString(16);
  return '${DateTime.now().microsecondsSinceEpoch}-$random';
}
