import 'dart:io';

import 'direct_transfer.dart';
import 'path_utils.dart';

// Re-export the generic API from the compatibility library for callers that
// already import photo_transfer.dart and want to migrate incrementally.
export 'direct_transfer.dart';

// Keep the original photo endpoint and public types as a migration shim. New
// callers should use DirectTransferClient/DirectTransferServer, which accept
// arbitrary files. Existing registrations continue to use /v1/photo.
const photoTransferPath = '/v1/photo';
const photoTransferMaxBytes = directTransferMaxBytes;

String? photoMimeTypeForName(String name) =>
    isPhotoFileName(name) ? mimeTypeForName(name) : null;

bool isSupportedPhotoTransfer({
  required String name,
  required String? mimeType,
}) {
  final expected = photoMimeTypeForName(name);
  if (expected == null || mimeType == null) return false;
  final actual = normalizeMimeType(mimeType);
  if (actual == expected) return true;
  final extension = fileExtension(name);
  return (extension == 'heic' && actual == 'image/heif') ||
      (extension == 'heif' && actual == 'image/heic');
}

/// Deprecated compatibility alias. Use [DirectTransferReceipt] for new
/// arbitrary-file transfers.
typedef PhotoTransferReceipt = DirectTransferReceipt;

/// Deprecated compatibility alias. Use [DirectTransferException] for new
/// arbitrary-file transfers.
typedef PhotoTransferException = DirectTransferException;

String? _validatePhotoTransfer(String name, String? mimeType) =>
    isSupportedPhotoTransfer(name: name, mimeType: mimeType)
    ? null
    : '照片类型不受支持。';

/// Compatibility wrapper around [DirectTransferServer] that retains the
/// historical /v1/photo route and its extension/MIME validation.
class PhotoTransferServer extends DirectTransferServer {
  PhotoTransferServer({
    required super.token,
    required super.saveDirectoryProvider,
    super.port = 0,
    super.bindAddress,
    super.endpointHost,
    super.requireExpectedSha256 = false,
  }) : super(
         transferPath: photoTransferPath,
         maxBytes: photoTransferMaxBytes,
         allowEmptyFiles: false,
         requestValidator: _validatePhotoTransfer,
       );

  static Future<InternetAddress?> findTailscaleIpv4Address() =>
      DirectTransferServer.findTailscaleIpv4Address();
}

/// Compatibility wrapper around [DirectTransferClient] that posts to the
/// historical photo endpoint. It intentionally does not restrict the client
/// itself; the receiver remains authoritative and enforces photo MIME/type.
class PhotoTransferClient extends DirectTransferClient {
  PhotoTransferClient({
    super.connectionTimeout = const Duration(seconds: 12),
    super.requestTimeout = const Duration(minutes: 30),
  }) : super(transferPath: photoTransferPath);
}
