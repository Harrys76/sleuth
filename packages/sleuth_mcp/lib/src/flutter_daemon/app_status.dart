/// State machine for a [DaemonSession]'s lifecycle.
enum AppSessionState {
  idle,
  attaching,
  ready,
  restarting,
  detaching,
  error,
}

/// MCP `app_status` tool response shape.
class AppStatusPayload {
  const AppStatusPayload({
    required this.attached,
    required this.state,
    this.device,
    this.appId,
    this.sessionUuid,
    this.launchMode,
    this.mode,
    this.lastError,
  });

  /// True iff the bridge is currently connected and serving tool calls.
  /// False during attaching / detaching / error.
  final bool attached;

  /// Device id reported by daemon (`app.start.deviceId`). Null when idle.
  final String? device;

  /// Daemon-assigned appId. Null when idle.
  final String? appId;

  /// Bridge's baseline sessionUuid from `ext.sleuth.diagnose`. Null when idle.
  final String? sessionUuid;

  /// `'attach'` (via flutter attach) or `'run'`. Null when idle.
  final String? launchMode;

  /// `'debug'` | `'profile'` | `'release'`. Null when idle.
  final String? mode;

  /// Current state enum as string. Required field.
  final String state;

  /// Human-readable description set when `state == 'error'`. Null otherwise.
  final String? lastError;

  Map<String, Object?> toJson() => <String, Object?>{
        'attached': attached,
        'state': state,
        if (device != null) 'device': device,
        if (appId != null) 'appId': appId,
        if (sessionUuid != null) 'sessionUuid': sessionUuid,
        if (launchMode != null) 'launchMode': launchMode,
        if (mode != null) 'mode': mode,
        if (lastError != null) 'lastError': lastError,
      };
}
