import 'dart:async';

class TransferCancelled implements Exception {
  const TransferCancelled();
}

class TransferDeferred implements Exception {
  const TransferDeferred();
}

class TransferControl {
  bool _paused = false;
  bool _cancelled = false;
  bool _deferred = false;
  Completer<void>? _resumeCompleter;
  void Function()? _onPause;
  void Function()? _onResume;
  Future<void> Function()? _onCancel;

  bool get isPaused => _paused;
  bool get isCancelled => _cancelled;
  bool get isDeferred => _deferred;

  void bind({
    void Function()? onPause,
    void Function()? onResume,
    Future<void> Function()? onCancel,
  }) {
    _onPause = onPause;
    _onResume = onResume;
    _onCancel = onCancel;
  }

  void pause() {
    if (_paused || _cancelled) return;
    _paused = true;
    _resumeCompleter = Completer<void>();
    _onPause?.call();
  }

  void resume() {
    if (!_paused || _cancelled) return;
    _paused = false;
    _onResume?.call();
    _resumeCompleter?.complete();
    _resumeCompleter = null;
  }

  Future<void> cancel() async {
    if (_cancelled) return;
    _cancelled = true;
    _paused = false;
    _resumeCompleter?.complete();
    _resumeCompleter = null;
    await _onCancel?.call();
  }

  /// Stops the current I/O without discarding its resumable partial file.
  Future<void> defer() async {
    if (_cancelled || _deferred) return;
    _deferred = true;
    _paused = false;
    _resumeCompleter?.complete();
    _resumeCompleter = null;
    await _onCancel?.call();
  }

  Future<void> checkpoint() async {
    if (_cancelled) throw const TransferCancelled();
    if (_deferred) throw const TransferDeferred();
    while (_paused) {
      await _resumeCompleter!.future;
      if (_cancelled) throw const TransferCancelled();
      if (_deferred) throw const TransferDeferred();
    }
  }
}
