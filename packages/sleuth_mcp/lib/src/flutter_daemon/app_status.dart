/// State machine for a [DaemonSession]'s lifecycle.
enum AppSessionState { idle, attaching, ready, restarting, detaching, error }

/// How the bridge's current VM service connection was opened, as reported
/// in `connectedVia`.
abstract final class ConnectedVia {
  /// `attach_app(device:)`, through `flutter attach --machine`.
  static const String attachDevice = 'attach_device';

  /// `attach_app(debugUrl:)`, straight to a known VM service URI.
  static const String attachDebugUrl = 'attach_debug_url';

  /// `attach_app(udid:, bundle:)`, through the iOS-direct pipeline.
  static const String attachIos = 'attach_ios';

  /// The `connect` tool, or `--uri` at sidecar startup.
  static const String connect = 'connect';

  static const List<String> values = [
    attachDevice,
    attachDebugUrl,
    attachIos,
    connect,
  ];
}

/// MCP `app_status` tool response shape.
class AppStatusPayload {
  const AppStatusPayload({
    required this.attached,
    required this.state,
    this.connected = false,
    this.connectedVia,
    this.device,
    this.appId,
    this.sessionUuid,
    this.launchMode,
    this.mode,
    this.lastError,
    this.transportMode,
    this.wsUri,
  });

  /// True when an `attach_app` session is `ready` and the bridge is still
  /// connected. False during attaching, detaching and error, after the
  /// bridge dropped, and for a connection opened with `connect`.
  final bool attached;

  /// True when the bridge holds a VM service connection, whichever tool
  /// opened it.
  final bool connected;

  /// How the current connection was opened: one of [ConnectedVia.values].
  /// Null when [connected] is false.
  final String? connectedVia;

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

  /// `'wired'` | `'wireless'` | `'unknown'` — set on iOS-direct
  /// sessions (`launchMode == 'ios-direct'`). Null otherwise.
  final String? transportMode;

  /// VM service WebSocket URI consumed by the bridge. Set on
  /// iOS-direct sessions so MCP clients can identify the connection.
  /// Null on daemon-attach (the daemon-provided wsUri is not exposed
  /// at this layer for compatibility with existing consumers).
  final String? wsUri;

  Map<String, Object?> toJson() {
    // transportMode + wsUri are part of the iOS-direct contract only.
    // Stripping them on other launch modes prevents accidental leakage
    // if a caller constructs a payload with both populated (e.g. a
    // partially-cleaned-up session struct during teardown). The
    // documented presence rule is "when launchMode == 'ios-direct'";
    // enforcement here makes the contract self-honouring.
    final isIosDirect = launchMode == 'ios-direct';
    return <String, Object?>{
      'attached': attached,
      'state': state,
      'connected': connected,
      if (connected && connectedVia != null) 'connectedVia': connectedVia,
      if (device != null) 'device': device,
      if (appId != null) 'appId': appId,
      if (sessionUuid != null) 'sessionUuid': sessionUuid,
      if (launchMode != null) 'launchMode': launchMode,
      if (mode != null) 'mode': mode,
      if (lastError != null) 'lastError': lastError,
      if (isIosDirect && transportMode != null) 'transportMode': transportMode,
      if (isIosDirect && wsUri != null) 'wsUri': wsUri,
    };
  }
}
