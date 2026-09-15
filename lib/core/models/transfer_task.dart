enum TransferDirection { upload, download, quickSend, quickReceive }

enum TransferStatus {
  queued,
  running,
  finalizing,
  completed,
  failed,
  cancelled,
}

/// The route requested by the sender before the transfer starts.
///
/// This is deliberately separate from [QuickTransferRoute]. A task can be
/// requested as reliable relay and use direct after a preflight probe confirms
/// that the relay network is unavailable. A direct request must remain direct;
/// the selected route records the actual route used by the task.
enum QuickTransferMode { direct, reliableRelay }

/// The route that was actually selected for a task.
enum QuickTransferRoute { direct, reliableRelay }

/// Operations that the current route can safely expose to the user.
///
/// Direct transfer is intentionally represented by a separate value instead
/// of relying on UI code to infer capabilities from the route. This keeps the
/// rule (no pause/resume/restart recovery for direct transfer) in the domain
/// model and leaves room for future protocol versions to express different
/// capabilities.
class TransferTaskCapabilities {
  const TransferTaskCapabilities({
    this.canPause = true,
    this.canResume = true,
    this.canRestartRecovery = true,
    this.canCancel = true,
    this.canRetryFromStart = true,
  });

  const TransferTaskCapabilities.direct()
    : canPause = false,
      canResume = false,
      canRestartRecovery = false,
      canCancel = true,
      canRetryFromStart = true;

  const TransferTaskCapabilities.reliableRelay()
    : canPause = true,
      canResume = true,
      canRestartRecovery = true,
      canCancel = true,
      canRetryFromStart = true;

  final bool canPause;
  final bool canResume;
  final bool canRestartRecovery;
  final bool canCancel;
  final bool canRetryFromStart;

  bool get supportsPause => canPause;

  bool get supportsResume => canResume;

  bool get supportsRestartRecovery => canRestartRecovery;

  bool get canRetry => canRetryFromStart;

  TransferTaskCapabilities copyWith({
    bool? canPause,
    bool? canResume,
    bool? canRestartRecovery,
    bool? canCancel,
    bool? canRetryFromStart,
  }) {
    return TransferTaskCapabilities(
      canPause: canPause ?? this.canPause,
      canResume: canResume ?? this.canResume,
      canRestartRecovery: canRestartRecovery ?? this.canRestartRecovery,
      canCancel: canCancel ?? this.canCancel,
      canRetryFromStart: canRetryFromStart ?? this.canRetryFromStart,
    );
  }
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
    bool supportsPause = true,
    bool supportsResume = true,
    bool supportsRestartRecovery = true,
    QuickTransferMode? requestedMode,
    QuickTransferMode? mode,
    QuickTransferRoute? route,
    QuickTransferRoute? actualRoute,
    TransferTaskCapabilities? capabilities,
  }) : requestedMode = requestedMode ?? mode,
       actualRoute = actualRoute ?? route,
       supportsPause = _isDirectRoute(route, actualRoute)
           ? false
           : supportsPause,
       supportsResume = _isDirectRoute(route, actualRoute)
           ? false
           : supportsResume,
       supportsRestartRecovery = _isDirectRoute(route, actualRoute)
           ? false
           : supportsRestartRecovery,
       capabilities = _isDirectRoute(route, actualRoute)
           ? (capabilities ?? const TransferTaskCapabilities()).copyWith(
               canPause: false,
               canResume: false,
               canRestartRecovery: false,
             )
           : capabilities ?? const TransferTaskCapabilities() {
    if (this.requestedMode == QuickTransferMode.direct &&
        this.actualRoute == QuickTransferRoute.reliableRelay) {
      throw ArgumentError.value(
        actualRoute,
        'actualRoute',
        'A direct request cannot fall back to reliable relay.',
      );
    }
  }

  final String id;
  final String name;
  final TransferDirection direction;
  final int totalBytes;
  int transferredBytes;
  TransferStatus status;
  String? error;

  /// Kept for source compatibility with the existing task UI.
  final bool supportsPause;

  /// Whether the protocol can continue a paused task.
  final bool supportsResume;

  /// Whether the task can be reconstructed after an app/process restart.
  final bool supportsRestartRecovery;

  /// The mode selected by the user before preflight.
  final QuickTransferMode? requestedMode;

  /// The route selected after preflight. It is null while the task is still
  /// waiting for route selection/probing.
  final QuickTransferRoute? actualRoute;

  /// Explicit route capabilities for UI and orchestration code.
  final TransferTaskCapabilities capabilities;

  bool cancelRequested = false;
  bool isPaused = false;

  bool get isDirect => actualRoute == QuickTransferRoute.direct;

  /// Short alias for callers that do not need to distinguish requested mode
  /// from the actual route.
  QuickTransferRoute? get route => actualRoute;

  /// Alias for callers that refer to the preflight choice as `mode`.
  QuickTransferMode? get mode => requestedMode;

  /// Direct transfer has no pause/resume/restart recovery even if an older
  /// caller forgot to pass the newer capability booleans.
  bool get canPause => !isDirect && supportsPause && capabilities.canPause;

  bool get canResume => !isDirect && supportsResume && capabilities.canResume;

  bool get canRestartRecovery =>
      !isDirect && supportsRestartRecovery && capabilities.canRestartRecovery;

  bool get canCancel => capabilities.canCancel;

  bool get canRetryFromStart => capabilities.canRetryFromStart;

  bool get supportsRetryFromStart => canRetryFromStart;

  double get progress => totalBytes == 0 ? 0 : transferredBytes / totalBytes;

  static bool _isDirectRoute(
    QuickTransferRoute? route,
    QuickTransferRoute? actualRoute,
  ) => (actualRoute ?? route) == QuickTransferRoute.direct;
}
