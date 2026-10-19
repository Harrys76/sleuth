import 'package:flutter/foundation.dart';

/// Where a Sleuth session is in its start-up.
enum SleuthRunPhase {
  /// The first VM connect attempt has not resolved yet.
  starting,

  /// Inside the frame-timing warm-up after start, when jank is not judged.
  warmingUp,

  /// Past warm-up.
  running,
}

/// The session's start-up phase and the state of its VM link.
@immutable
class SleuthRunState {
  const SleuthRunState({
    this.phase = SleuthRunPhase.starting,
    this.vmConnected = false,
    this.reconnectAttempt,
    this.maxReconnectAttempts = 0,
    this.stoppedRetrying = false,
  });

  final SleuthRunPhase phase;

  final bool vmConnected;

  /// The background reconnect attempt that is waiting or running, counted
  /// from 1, or null when none is.
  final int? reconnectAttempt;

  /// How many background reconnect attempts the session makes before it
  /// stops.
  final int maxReconnectAttempts;

  /// The VM is not connected and the background attempts are used up.
  /// A manual reconnect can still succeed.
  final bool stoppedRetrying;

  @override
  bool operator ==(Object other) =>
      other is SleuthRunState &&
      other.phase == phase &&
      other.vmConnected == vmConnected &&
      other.reconnectAttempt == reconnectAttempt &&
      other.maxReconnectAttempts == maxReconnectAttempts &&
      other.stoppedRetrying == stoppedRetrying;

  @override
  int get hashCode => Object.hash(
    phase,
    vmConnected,
    reconnectAttempt,
    maxReconnectAttempts,
    stoppedRetrying,
  );

  @override
  String toString() =>
      'SleuthRunState(${phase.name}, vm: $vmConnected, '
      'attempt: $reconnectAttempt/$maxReconnectAttempts, '
      'stopped: $stoppedRetrying)';
}
