enum TransferDirection { upload, download, quickSend, quickReceive }

enum TransferStatus {
  queued,
  running,
  finalizing,
  completed,
  failed,
  cancelled,
}

class TransferTask {
  TransferTask({
    required this.id,
    required this.name,
    required this.direction,
    required this.totalBytes,
    this.transferredBytes = 0,
    this.status = TransferStatus.queued,
    this.error,
    this.supportsPause = true,
  });

  final String id;
  final String name;
  final TransferDirection direction;
  final int totalBytes;
  int transferredBytes;
  TransferStatus status;
  String? error;
  final bool supportsPause;
  bool cancelRequested = false;
  bool isPaused = false;

  double get progress => totalBytes == 0 ? 0 : transferredBytes / totalBytes;
}
