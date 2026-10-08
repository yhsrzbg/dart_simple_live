import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_tv_app/modules/live_room/douyu_playback_recovery.dart';

void main() {
  DouyuPlaybackRecovery recovery() =>
      DouyuPlaybackRecovery(retryDelay: Duration.zero);
  test('every failure tries fresh acquisition, at most three times', () async {
    final r = recovery();
    final attempts = <int>[];
    final result = await r.recover((attempt, current) async {
      attempts.add(attempt);
      throw StateError('failed acquisition');
    });
    expect(result, DouyuRecoveryResult.exhausted);
    expect(attempts, [1, 2, 3]);
    expect(
        await r.recover((a, c) async => true), DouyuRecoveryResult.exhausted);
  });
  test('short opens do not reset the failure budget', () async {
    final r = recovery();
    for (var i = 0; i < 3; i++) {
      expect(
          await r.recover((a, c) async => true), DouyuRecoveryResult.recovered);
    }
    expect(
        await r.recover((a, c) async => true), DouyuRecoveryResult.exhausted);
  });
  test('only sustained advancing unbuffered playback renews budget', () async {
    final r = recovery();
    await r.recover((a, c) async => true);
    final now = DateTime.utc(2026);
    for (var second = 0; second <= 10; second++) {
      r.observeProgress(Duration(seconds: second),
          playing: true,
          buffering: false,
          now: now.add(Duration(seconds: second)));
    }
    expect(r.attempts, 1);
    r.observeProgress(const Duration(seconds: 11),
        playing: true,
        buffering: true,
        now: now.add(const Duration(seconds: 11)));
    for (var second = 12; second <= 44; second++) {
      r.observeProgress(Duration(seconds: second),
          playing: true,
          buffering: false,
          now: now.add(Duration(seconds: second)));
    }
    expect(r.attempts, 0);
  });
  test('stalled position cannot renew budget', () async {
    final r = recovery();
    await r.recover((a, c) async => true);
    for (var i = 0; i < 60; i++) {
      r.observeProgress(const Duration(seconds: 1),
          playing: true,
          buffering: false,
          now: DateTime.utc(2026).add(Duration(seconds: i)));
    }
    expect(r.attempts, 1);
  });
  test('duplicate errors do not start overlapping acquisition', () async {
    final r = recovery();
    final pending = Completer<bool>();
    final first = r.recover((a, c) => pending.future);
    expect(await r.recover((a, c) async => true), DouyuRecoveryResult.ignored);
    pending.complete(true);
    expect(await first, DouyuRecoveryResult.recovered);
  });
  test('room quality or account change invalidates the old result', () async {
    final r = recovery();
    final pending = Completer<bool>();
    bool Function()? oldCurrent;
    final first = r.recover((a, c) {
      oldCurrent = c;
      return pending.future;
    });
    r.invalidate();
    expect(oldCurrent!(), isFalse);
    final secondPending = Completer<bool>();
    final second = r.recover((a, c) => secondPending.future);
    pending.complete(true);
    expect(await first, DouyuRecoveryResult.ignored);
    expect(r.running, isTrue);
    secondPending.complete(true);
    expect(await second, DouyuRecoveryResult.recovered);
  });
  test('close discards pending recovery and prevents another open', () async {
    final r = recovery();
    final pending = Completer<bool>();
    bool Function()? current;
    final task = r.recover((a, c) {
      current = c;
      return pending.future;
    });
    r.close();
    expect(current!(), isFalse);
    pending.complete(true);
    expect(await task, DouyuRecoveryResult.ignored);
    expect(await r.recover((a, c) async => true), DouyuRecoveryResult.ignored);
  });
}
