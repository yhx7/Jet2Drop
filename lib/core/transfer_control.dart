import 'dart:async';

class TransferCancelled implements Exception {
  const TransferCancelled();
}

class TransferControl {
  bool _paused = false;
  bool _cancelled = false;
  Completer<void>? _resumeCompleter;
  void Function()? _onPause;
  void Function()? _onResume;
  Future<void> Function()? _onCancel;

  bool get isPaused => _paused;
  bool get isCancelled => _cancelled;

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

  Future<void> checkpoint() async {
    if (_cancelled) throw const TransferCancelled();
    while (_paused) {
      await _resumeCompleter!.future;
      if (_cancelled) throw const TransferCancelled();
    }
  }
}
