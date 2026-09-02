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

/// Produces one filename that is safe on Android, Windows and common SFTP
/// servers while retaining a useful extension where possible.
String sanitizeTransferFileName(String value, {int maxLength = 180}) {
  var name = value.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_').trim();
  name = name.replaceAll(RegExp(r'[. ]+$'), '');
  if (name.isEmpty || name == '.' || name == '..') name = 'unnamed-file';
  const reserved = {
    'con',
    'prn',
    'aux',
    'nul',
    'com1',
    'com2',
    'com3',
    'com4',
    'com5',
    'com6',
    'com7',
    'com8',
    'com9',
    'lpt1',
    'lpt2',
    'lpt3',
    'lpt4',
    'lpt5',
    'lpt6',
    'lpt7',
    'lpt8',
    'lpt9',
  };
  final dot = name.lastIndexOf('.');
  final base = (dot > 0 ? name.substring(0, dot) : name).toLowerCase();
  if (reserved.contains(base)) name = '_$name';
  if (name.length <= maxLength) return name;
  final extension = dot > 0 && name.length - dot <= 20
      ? name.substring(dot)
      : '';
  final keep = maxLength - extension.length;
  return '${name.substring(0, keep)}$extension';
}
