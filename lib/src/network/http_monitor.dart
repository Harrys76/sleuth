import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'request_record.dart';

/// Chaining [HttpOverrides] that wraps every [HttpClient] with a monitoring
/// proxy. Records request timing, status, and response size without modifying
/// behavior. Preserves any previously installed overrides via delegation.
class SleuthHttpOverrides extends HttpOverrides {
  SleuthHttpOverrides({
    required this.onRecord,
    this.onRequestStarted,
    this.onRequestEnded,
    this.excludePatterns,
  }) : _previous = HttpOverrides.current;

  /// Callback invoked when a monitored request completes (or fails).
  final void Function(RequestRecord) onRecord;

  /// Callback invoked when an HTTP request starts (before response).
  final void Function(int requestId, DateTime startedAt)? onRequestStarted;

  /// Callback invoked when an HTTP request completes or fails.
  final void Function(int requestId)? onRequestEnded;

  /// URL substring patterns to exclude from monitoring (e.g. analytics).
  final List<String>? excludePatterns;

  /// The override that was active when this instance was created.
  final HttpOverrides? _previous;

  /// Install this override as [HttpOverrides.global].
  static void install(SleuthHttpOverrides overrides) {
    HttpOverrides.global = overrides;
  }

  /// Restore [HttpOverrides.global] to the previous override.
  /// Only restores if the current global is still [overrides] — another
  /// package may have overwritten us since installation.
  static void uninstall(SleuthHttpOverrides overrides) {
    if (HttpOverrides.current == overrides) {
      HttpOverrides.global = overrides._previous;
    }
  }

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final inner =
        _previous?.createHttpClient(context) ?? super.createHttpClient(context);
    return _MonitoringHttpClient(
      inner,
      onRecord,
      excludePatterns,
      onRequestStarted,
      onRequestEnded,
    );
  }

  @override
  String findProxyFromEnvironment(Uri url, Map<String, String>? environment) {
    return _previous?.findProxyFromEnvironment(url, environment) ??
        super.findProxyFromEnvironment(url, environment);
  }
}

// ---------------------------------------------------------------------------
// Monitoring HttpClient proxy
// ---------------------------------------------------------------------------

/// Wraps an [HttpClient], intercepting all request-creating methods to
/// record timing and response size. All other methods delegate unchanged.
class _MonitoringHttpClient implements HttpClient {
  _MonitoringHttpClient(
    this._inner,
    this._onRecord,
    this._excludePatterns,
    this._onRequestStarted,
    this._onRequestEnded,
  );

  final HttpClient _inner;
  final void Function(RequestRecord) _onRecord;
  final List<String>? _excludePatterns;
  final void Function(int requestId, DateTime startedAt)? _onRequestStarted;
  final void Function(int requestId)? _onRequestEnded;

  static int _nextRequestId = 0;

  bool _isExcluded(Uri url) {
    final patterns = _excludePatterns;
    if (patterns == null || patterns.isEmpty) return false;
    final urlStr = url.toString();
    for (final pattern in patterns) {
      if (urlStr.contains(pattern)) return true;
    }
    return false;
  }

  // -- Request-creating methods: all route through openUrl() --

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    if (_isExcluded(url)) return _inner.openUrl(method, url);
    final startTime = DateTime.now();
    final requestId = _nextRequestId++;
    _onRequestStarted?.call(requestId, startTime);
    try {
      final request = await _inner.openUrl(method, url);
      return _MonitoringRequest(
        request,
        url.toString(),
        method,
        startTime,
        _onRecord,
        requestId,
        _onRequestEnded,
      );
    } catch (_) {
      try {
        _onRequestEnded?.call(requestId);
      } catch (_) {
        // Non-fatal: monitoring must not alter app behavior.
      }
      try {
        _onRecord(RequestRecord(
          url: url.toString(),
          method: method,
          statusCode: -1,
          durationMs: DateTime.now().difference(startTime).inMilliseconds,
          responseBytes: 0,
          startedAt: startTime,
        ));
      } catch (_) {
        // Non-fatal: monitoring must not alter app behavior.
      }
      rethrow;
    }
  }

  @override
  Future<HttpClientRequest> open(
      String method, String host, int port, String path) {
    // Best-effort scheme inference — HttpClient.open() has no scheme parameter.
    // Port 443 → https; all others default to http. This only affects the
    // recorded URL string, not the actual connection.
    final scheme = port == 443 ? 'https' : 'http';
    return openUrl(
        method, Uri(scheme: scheme, host: host, port: port, path: path));
  }

  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      open('get', host, port, path);

  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('get', url);

  @override
  Future<HttpClientRequest> post(String host, int port, String path) =>
      open('post', host, port, path);

  @override
  Future<HttpClientRequest> postUrl(Uri url) => openUrl('post', url);

  @override
  Future<HttpClientRequest> put(String host, int port, String path) =>
      open('put', host, port, path);

  @override
  Future<HttpClientRequest> putUrl(Uri url) => openUrl('put', url);

  @override
  Future<HttpClientRequest> delete(String host, int port, String path) =>
      open('delete', host, port, path);

  @override
  Future<HttpClientRequest> deleteUrl(Uri url) => openUrl('delete', url);

  @override
  Future<HttpClientRequest> patch(String host, int port, String path) =>
      open('patch', host, port, path);

  @override
  Future<HttpClientRequest> patchUrl(Uri url) => openUrl('patch', url);

  @override
  Future<HttpClientRequest> head(String host, int port, String path) =>
      open('head', host, port, path);

  @override
  Future<HttpClientRequest> headUrl(Uri url) => openUrl('head', url);

  // -- Delegated properties --

  @override
  Duration get idleTimeout => _inner.idleTimeout;
  @override
  set idleTimeout(Duration value) => _inner.idleTimeout = value;

  @override
  Duration? get connectionTimeout => _inner.connectionTimeout;
  @override
  set connectionTimeout(Duration? value) => _inner.connectionTimeout = value;

  @override
  int? get maxConnectionsPerHost => _inner.maxConnectionsPerHost;
  @override
  set maxConnectionsPerHost(int? value) => _inner.maxConnectionsPerHost = value;

  @override
  bool get autoUncompress => _inner.autoUncompress;
  @override
  set autoUncompress(bool value) => _inner.autoUncompress = value;

  @override
  String? get userAgent => _inner.userAgent;
  @override
  set userAgent(String? value) => _inner.userAgent = value;

  // -- Setter-only callbacks --

  @override
  set authenticate(
          Future<bool> Function(Uri url, String scheme, String? realm)? f) =>
      _inner.authenticate = f;

  @override
  set authenticateProxy(
          Future<bool> Function(
                  String host, int port, String scheme, String? realm)?
              f) =>
      _inner.authenticateProxy = f;

  @override
  set findProxy(String Function(Uri url)? f) => _inner.findProxy = f;

  @override
  set badCertificateCallback(
          bool Function(X509Certificate cert, String host, int port)?
              callback) =>
      _inner.badCertificateCallback = callback;

  @override
  set connectionFactory(
          Future<ConnectionTask<Socket>> Function(
                  Uri url, String? proxyHost, int? proxyPort)?
              f) =>
      _inner.connectionFactory = f;

  @override
  set keyLog(Function(String line)? callback) => _inner.keyLog = callback;

  // -- Credential methods --

  @override
  void addCredentials(
          Uri url, String realm, HttpClientCredentials credentials) =>
      _inner.addCredentials(url, realm, credentials);

  @override
  void addProxyCredentials(
          String host, int port, String realm, HttpClientCredentials cred) =>
      _inner.addProxyCredentials(host, port, realm, cred);

  // -- Lifecycle --

  @override
  void close({bool force = false}) => _inner.close(force: force);
}

// ---------------------------------------------------------------------------
// Monitoring HttpClientRequest proxy
// ---------------------------------------------------------------------------

class _MonitoringRequest implements HttpClientRequest {
  _MonitoringRequest(
    this._inner,
    this._url,
    this._method,
    this._startTime,
    this._onRecord,
    this._requestId,
    this._onRequestEnded,
  );

  final HttpClientRequest _inner;
  final String _url;
  final String _method;
  final DateTime _startTime;
  final void Function(RequestRecord) _onRecord;
  final int _requestId;
  final void Function(int requestId)? _onRequestEnded;

  @override
  Future<HttpClientResponse> close() async {
    try {
      final response = await _inner.close();
      return _MonitoringResponse(
        response,
        _url,
        _method,
        _startTime,
        _onRecord,
        _requestId,
        _onRequestEnded,
      );
    } catch (_) {
      try {
        _onRequestEnded?.call(_requestId);
      } catch (_) {
        // Non-fatal: monitoring must not alter app behavior.
      }
      try {
        _onRecord(RequestRecord(
          url: _url,
          method: _method,
          statusCode: -1,
          durationMs: DateTime.now().difference(_startTime).inMilliseconds,
          responseBytes: 0,
          startedAt: _startTime,
        ));
      } catch (_) {
        // Non-fatal: monitoring must not alter app behavior.
      }
      rethrow;
    }
  }

  // -- Full delegation --

  @override
  bool get bufferOutput => _inner.bufferOutput;
  @override
  set bufferOutput(bool value) => _inner.bufferOutput = value;

  @override
  int get contentLength => _inner.contentLength;
  @override
  set contentLength(int value) => _inner.contentLength = value;

  @override
  Encoding get encoding => _inner.encoding;
  @override
  set encoding(Encoding value) => _inner.encoding = value;

  @override
  bool get followRedirects => _inner.followRedirects;
  @override
  set followRedirects(bool value) => _inner.followRedirects = value;

  @override
  int get maxRedirects => _inner.maxRedirects;
  @override
  set maxRedirects(int value) => _inner.maxRedirects = value;

  @override
  bool get persistentConnection => _inner.persistentConnection;
  @override
  set persistentConnection(bool value) => _inner.persistentConnection = value;

  @override
  HttpHeaders get headers => _inner.headers;

  @override
  List<Cookie> get cookies => _inner.cookies;

  @override
  Uri get uri => _inner.uri;

  @override
  String get method => _inner.method;

  @override
  HttpConnectionInfo? get connectionInfo => _inner.connectionInfo;

  @override
  Future<HttpClientResponse> get done => _inner.done;

  @override
  void abort([Object? exception, StackTrace? stackTrace]) =>
      _inner.abort(exception, stackTrace);

  // -- IOSink delegation --

  @override
  void add(List<int> data) => _inner.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);

  @override
  Future addStream(Stream<List<int>> stream) => _inner.addStream(stream);

  @override
  Future flush() => _inner.flush();

  @override
  void write(Object? object) => _inner.write(object);

  @override
  void writeAll(Iterable objects, [String separator = '']) =>
      _inner.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => _inner.writeCharCode(charCode);

  @override
  void writeln([Object? object = '']) => _inner.writeln(object);
}

// ---------------------------------------------------------------------------
// Monitoring HttpClientResponse proxy
// ---------------------------------------------------------------------------

/// Extends [Stream] so that all stream convenience methods (toList, drain,
/// forEach, fold, etc.) route through our [listen] override. This ensures
/// byte counting and record emission work regardless of how the consumer
/// reads the response body.
class _MonitoringResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _MonitoringResponse(
    this._inner,
    this._url,
    this._method,
    this._startTime,
    this._onRecord,
    this._requestId,
    this._onRequestEnded,
  );

  final HttpClientResponse _inner;
  final String _url;
  final String _method;
  final DateTime _startTime;
  final void Function(RequestRecord) _onRecord;
  final int _requestId;
  final void Function(int requestId)? _onRequestEnded;

  void _emitRecord(int bytesReceived, {bool cancelled = false}) {
    try {
      _onRequestEnded?.call(_requestId);
    } catch (_) {
      // Non-fatal: monitoring must not alter app behavior.
    }
    try {
      _onRecord(RequestRecord(
        url: _url,
        method: _method,
        statusCode: _inner.statusCode,
        durationMs: DateTime.now().difference(_startTime).inMilliseconds,
        responseBytes: bytesReceived,
        startedAt: _startTime,
        cancelled: cancelled,
      ));
    } catch (_) {
      // Non-fatal: monitoring must not alter app behavior.
    }
  }

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    // Terminal-event plumbing decoupled from what the caller passes:
    //
    // - `Stream.drain()` internally calls
    //   `listen(null, cancelOnError: true).asFuture(futureValue)`, and
    //   `StreamSubscription.asFuture()` REPLACES the subscription's
    //   `_onDone` — so we route `asFuture()` through our own Completer
    //   instead of delegating to `_inner.asFuture()`.
    //
    // - Consumers can legitimately do
    //   `final sub = response.listen(...); sub.onDone(...);` (or
    //   `sub.onError(...)`) to rebind terminal callbacks AFTER listen.
    //   If those setters were forwarded to `_inner`, they would strip
    //   the closures that call `_emitRecord` — resurfacing AB1 via a
    //   new vector. To guard against that, the inner subscription's
    //   handlers are PERMANENTLY owned by this proxy; the wrapper
    //   stores user-supplied callbacks in mutable fields and the
    //   permanent handlers dereference those fields at call time.
    //   `sub.onDone(newCb)` mutates the wrapper's field — it never
    //   touches `_inner`'s terminal handler, so record emission
    //   survives rebinding.
    final sub = _MonitoringSubscription<List<int>>._(_emitRecord);
    // Suppress unhandled-async-error on the terminal future — if the
    // caller never asks for it via `asFuture`, any error we forward
    // into the completer would otherwise surface as an uncaught
    // asynchronous error in tests/prod. Callers that DO use
    // `asFuture` will chain .then/.catchError and receive the error.
    sub._terminated.future.ignore();
    sub._userOnData = onData;
    sub._userOnError = onError;
    sub._userOnDone = onDone;

    sub._inner = _inner.listen(
      (chunk) {
        sub._bytesReceived += chunk.length;
        sub._userOnData?.call(chunk);
      },
      onError: (Object error, [StackTrace? stackTrace]) {
        final stack = stackTrace ?? StackTrace.empty;
        sub._emitOnTerminalWithError(error, stack);
        final handler = sub._userOnError;
        if (handler != null) {
          if (handler is void Function(Object, StackTrace)) {
            handler(error, stack);
          } else {
            (handler as void Function(Object))(error);
          }
        }
      },
      onDone: () {
        sub._emitOnTerminal();
        sub._userOnDone?.call();
      },
      cancelOnError: cancelOnError,
    );

    return sub;
  }

  // -- HttpClientResponse properties (not inherited from Stream) --

  @override
  int get statusCode => _inner.statusCode;

  @override
  String get reasonPhrase => _inner.reasonPhrase;

  @override
  HttpHeaders get headers => _inner.headers;

  @override
  int get contentLength => _inner.contentLength;

  @override
  HttpClientResponseCompressionState get compressionState =>
      _inner.compressionState;

  @override
  List<Cookie> get cookies => _inner.cookies;

  @override
  bool get isRedirect => _inner.isRedirect;

  @override
  bool get persistentConnection => _inner.persistentConnection;

  @override
  List<RedirectInfo> get redirects => _inner.redirects;

  @override
  X509Certificate? get certificate => _inner.certificate;

  @override
  HttpConnectionInfo? get connectionInfo => _inner.connectionInfo;

  @override
  bool get isBroadcast => _inner.isBroadcast;

  @override
  Future<HttpClientResponse> redirect(
          [String? method, Uri? url, bool? followLoops]) =>
      _inner.redirect(method, url, followLoops);

  @override
  Future<Socket> detachSocket() => _inner.detachSocket();
}

/// Wrapping [StreamSubscription] that owns the terminal-event signal so
/// the proxy's [RequestRecord] always lands, regardless of how the caller
/// consumes the response.
///
/// The wrapper addresses two failure modes:
///
/// 1. `Stream.drain()` calls `listen(null, cancelOnError: true).asFuture()`
///    and `StreamSubscription.asFuture()` REPLACES the subscription's
///    `_onDone` with its own handler — so a proxy that depends on a
///    wrapping `onDone` closure to emit its terminal record silently
///    loses the event. [asFuture] here completes from a [Completer]
///    driven by the proxy's own emit path instead of delegating.
///
/// 2. Post-listen rebinding — `final sub = response.listen(...);
///    sub.onDone(newCb);` — previously forwarded straight to the inner
///    subscription, which replaced the proxy's wrapping closures and
///    recreated the drop-record failure mode via a different vector.
///    Here the inner subscription's handlers are PERMANENTLY owned by
///    this wrapper: they dereference [_userOnData] / [_userOnError] /
///    [_userOnDone] at call time, and the wrapper's setters mutate those
///    fields instead of touching `_inner`. Rebinding can never strip the
///    emit path.
class _MonitoringSubscription<T> implements StreamSubscription<T> {
  _MonitoringSubscription._(this._emit);

  /// Assigned immediately after construction by [_MonitoringResponse.listen].
  late StreamSubscription<T> _inner;

  /// Completes when the stream terminates (naturally, via error, or via
  /// cancel). `asFuture()` chains from here so `Stream.drain()` and
  /// hand-written `asFuture()` callers receive the terminal signal even
  /// though the inner subscription's `_onDone` was installed by this
  /// proxy, not the caller.
  final Completer<void> _terminated = Completer<void>();

  /// Bytes observed on the inner stream. Incremented in the permanent
  /// `onData` handler before dispatching to the user callback.
  int _bytesReceived = 0;

  /// Guards against double-emit. `_emitOnTerminal` and
  /// `_emitOnTerminalWithError` may race — e.g., a server closes the
  /// socket just as the consumer cancels — and [_emit] must run exactly
  /// once per request.
  bool _terminatedFlag = false;

  /// Proxy-owned emit path. Invoked by terminal handlers on the inner
  /// subscription and by [cancel]. Signature matches
  /// `_MonitoringResponse._emitRecord`.
  final void Function(int bytesReceived, {bool cancelled}) _emit;

  /// Mutable user callbacks. The inner subscription's handlers read these
  /// at call time, so rebinding via [onData] / [onError] / [onDone]
  /// mutates the fields and the emit path stays intact.
  void Function(T data)? _userOnData;
  Function? _userOnError;
  void Function()? _userOnDone;

  /// Emit a terminal record and complete [_terminated]. Idempotent.
  void _emitOnTerminal({bool cancelled = false}) {
    if (_terminatedFlag) return;
    _terminatedFlag = true;
    _emit(_bytesReceived, cancelled: cancelled);
    if (!_terminated.isCompleted) {
      _terminated.complete();
    }
  }

  /// Emit a terminal record and surface the error to `asFuture()` chainers.
  /// Idempotent.
  void _emitOnTerminalWithError(Object error, StackTrace stackTrace) {
    if (_terminatedFlag) return;
    _terminatedFlag = true;
    _emit(_bytesReceived, cancelled: false);
    if (!_terminated.isCompleted) {
      _terminated.completeError(error, stackTrace);
    }
  }

  @override
  Future<E> asFuture<E>([E? futureValue]) =>
      _terminated.future.then<E>((_) => futureValue as E);

  @override
  Future<void> cancel() {
    // Cancel-before-terminate is treated as a terminal event so the
    // `RequestRecord` still lands — otherwise `_activeRequests` would
    // leak and `pendingRequestSnapshot()` attribution would be poisoned
    // for later verdicts. Marked `cancelled: true` so the detector can
    // distinguish aborts from completions.
    _emitOnTerminal(cancelled: true);
    return _inner.cancel();
  }

  @override
  void onData(void Function(T data)? handleData) {
    _userOnData = handleData;
  }

  @override
  void onError(Function? handleError) {
    _userOnError = handleError;
  }

  @override
  void onDone(void Function()? handleDone) {
    _userOnDone = handleDone;
  }

  @override
  void pause([Future<void>? resumeSignal]) => _inner.pause(resumeSignal);

  @override
  void resume() => _inner.resume();

  @override
  bool get isPaused => _inner.isPaused;
}
