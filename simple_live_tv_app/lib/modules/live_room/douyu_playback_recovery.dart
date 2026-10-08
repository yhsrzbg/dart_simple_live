enum DouyuRecoveryResult { recovered, exhausted, ignored }

/// Bounded fresh-URL recovery. A short successful open does not renew its budget.
class DouyuPlaybackRecovery {
  DouyuPlaybackRecovery(
      {this.maxAttempts = 3,
      this.retryDelay = const Duration(seconds: 1),
      this.healthyDuration = const Duration(seconds: 30)});
  final int maxAttempts;
  final Duration retryDelay;
  final Duration healthyDuration;
  int _generation = 0;
  int attempts = 0;
  bool running = false;
  bool _closed = false;
  DateTime? _healthySince;
  DateTime? _lastProgress;
  Duration? _position;

  void invalidate() {
    ++_generation;
    attempts = 0;
    running = false;
    _clearHealth();
  }

  void close() {
    _closed = true;
    invalidate();
  }

  void _clearHealth() {
    _healthySince = null;
    _lastProgress = null;
    _position = null;
  }

  void observeProgress(Duration position,
      {required bool playing, required bool buffering, required DateTime now}) {
    if (_closed || running) return;
    if (!playing ||
        buffering ||
        (_position != null && position <= _position!)) {
      _clearHealth();
      _position = position;
      return;
    }
    if (_lastProgress != null &&
        now.difference(_lastProgress!) > const Duration(seconds: 3)) {
      _healthySince = null;
    }
    if (_position != null) _healthySince ??= now;
    _position = position;
    _lastProgress = now;
    if (_healthySince != null &&
        now.difference(_healthySince!) >= healthyDuration) attempts = 0;
  }

  Future<DouyuRecoveryResult> recover(
      Future<bool> Function(int attempt, bool Function() isCurrent)
          refresh) async {
    if (_closed || running) return DouyuRecoveryResult.ignored;
    final generation = _generation;
    bool current() => !_closed && generation == _generation;
    running = true;
    _clearHealth();
    try {
      while (attempts < maxAttempts && current()) {
        final attempt = ++attempts;
        try {
          final opened = await refresh(attempt, current);
          if (!current()) return DouyuRecoveryResult.ignored;
          if (opened) return DouyuRecoveryResult.recovered;
        } catch (_) {
          if (!current()) return DouyuRecoveryResult.ignored;
        }
        if (attempts < maxAttempts) await Future<void>.delayed(retryDelay);
      }
      return current()
          ? DouyuRecoveryResult.exhausted
          : DouyuRecoveryResult.ignored;
    } finally {
      if (current()) running = false;
    }
  }
}
