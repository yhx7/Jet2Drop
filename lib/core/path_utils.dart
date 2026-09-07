import 'dart:math';

const _mimeTypesByExtension = <String, String>{
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
  'webp': 'image/webp',
  'gif': 'image/gif',
  'bmp': 'image/bmp',
  'heic': 'image/heic',
  'heif': 'image/heif',
  'avif': 'image/avif',
  'mp4': 'video/mp4',
  'mov': 'video/quicktime',
  'mkv': 'video/x-matroska',
  'webm': 'video/webm',
  'avi': 'video/x-msvideo',
  'mp3': 'audio/mpeg',
  'm4a': 'audio/mp4',
  'wav': 'audio/wav',
  'flac': 'audio/flac',
};

// These are the image formats Flutter can preview consistently on all of the
// supported desktop and mobile runtimes.  HEIC/AVIF remain valid transfer
// formats, but are left to the system viewer when preview support is absent.
const _previewImageExtensions = <String>{
  'jpg',
  'jpeg',
  'png',
  'webp',
  'gif',
  'bmp',
};

String fileExtension(String name) {
  final dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
}

String mimeTypeForName(String name) =>
    _mimeTypesByExtension[fileExtension(name)] ?? 'application/octet-stream';

bool isPhotoFileName(String name) => isImageMimeType(mimeTypeForName(name));

bool isPreviewImageFileName(String name) =>
    _previewImageExtensions.contains(fileExtension(name));

bool isAudioFileName(String name) => isAudioMimeType(mimeTypeForName(name));

bool isVideoFileName(String name) => isVideoMimeType(mimeTypeForName(name));

String normalizeMimeType(String? value) =>
    value?.split(';').first.trim().toLowerCase() ?? '';

bool isImageMimeType(String? value) =>
    normalizeMimeType(value).startsWith('image/');

bool isVideoMimeType(String? value) =>
    normalizeMimeType(value).startsWith('video/');

bool isAudioMimeType(String? value) =>
    normalizeMimeType(value).startsWith('audio/');

bool isMediaMimeType(String? value) =>
    isImageMimeType(value) || isVideoMimeType(value);

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
