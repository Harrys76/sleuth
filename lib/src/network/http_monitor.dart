import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'request_record.dart';

/// Chaining [HttpOverrides] that wraps every [HttpClient] with a monitoring
/// proxy. Records request timing, status, and response size without modifying
/// behavior. Preserves any previously installed overrides via delegation.
class WatchdogHttpOverrides extends HttpOverrides {
  WatchdogHttpOverrides({
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
  static void install(WatchdogHttpOverrides overrides) {
    HttpOverrides.global = overrides;
  }

  /// Restore [HttpOverrides.global] to the previous override.
  /// Only restores if the current global is still [overrides] — another
  /// package may have overwritten us since installation.
  static void uninstall(WatchdogHttpOverrides overrides) {
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

  void _emitRecord(int bytesReceived) {
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
    int bytesReceived = 0;
    bool recorded = false;
    return _inner.listen(
      (chunk) {
        bytesReceived += chunk.length;
        onData?.call(chunk);
      },
      onError: (Object error, [StackTrace? stackTrace]) {
        if (!recorded) {
          recorded = true;
          _emitRecord(bytesReceived);
        }
        if (onError != null) {
          if (onError is void Function(Object, StackTrace)) {
            onError(error, stackTrace ?? StackTrace.empty);
          } else {
            (onError as void Function(Object))(error);
          }
        }
      },
      onDone: () {
        if (!recorded) {
          recorded = true;
          _emitRecord(bytesReceived);
        }
        onDone?.call();
      },
      cancelOnError: cancelOnError,
    );
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
