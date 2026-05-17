import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';

import '../bridge/vm_bridge.dart';
import '../resources/causal_graph.dart';
import '../resources/encyclopedia.dart';
import '../tools/tools.dart';
import 'mcp_protocol.dart';
import 'mcp_types.dart';

const String mcpProtocolVersion = '2024-11-05';

/// Protocol versions the server can speak. When a client sends `initialize`
/// with one of these, the server echoes it back; otherwise the server
/// replies with [mcpProtocolVersion] and the client decides whether to
/// continue or disconnect (per MCP spec).
const Set<String> supportedMcpProtocolVersions = {
  '2024-11-05',
  '2025-03-26',
  '2025-06-18',
};

const String sleuthMcpVersion = '0.1.0';
const String sleuthPackageVersionPin = '0.32.0';

/// Tool handler signature. Returns either a `data` map (wrapped as text
/// content) or a `ToolCallResult` directly when the handler needs full
/// control over the response shape.
typedef ToolHandler = Future<Object> Function(
  VmBridge bridge,
  Map<String, Object?> args,
);

class _RegisteredTool {
  _RegisteredTool({required this.descriptor, required this.handler});
  final Tool descriptor;
  final ToolHandler handler;
}

class _RegisteredResource {
  _RegisteredResource({required this.descriptor, required this.read});
  final Resource descriptor;
  final Future<Map<String, Object?>> Function(VmBridge) read;
}

class McpServer {
  McpServer({
    required this.bridge,
    Duration toolTimeout = const Duration(seconds: 10),
    Sink<String>? logger,
  })  : _toolTimeout = toolTimeout,
        _logger = logger;

  final VmBridge bridge;
  final Duration _toolTimeout;
  final Sink<String>? _logger;
  late final EncyclopediaResource _encyclopedia =
      EncyclopediaResource(bridge: bridge);
  late final CausalGraphResource _causalGraph =
      CausalGraphResource(bridge: bridge);
  bool _initialized = false;
  final Map<String, _RegisteredTool> _tools = {};
  final Map<String, _RegisteredResource> _resources = {};

  void registerDefaults() {
    for (final entry in builtInTools.entries) {
      _tools[entry.key] = _RegisteredTool(
        descriptor: entry.value.descriptor,
        handler: entry.value.handler,
      );
    }
    _resources['sleuth://encyclopedia'] = _RegisteredResource(
      descriptor: const Resource(
        uri: 'sleuth://encyclopedia',
        name: 'Sleuth Encyclopedia',
        description: 'Per-issue explanations keyed by canonical stableId.',
        mimeType: 'application/json',
      ),
      read: (b) => _encyclopedia.read(),
    );
    _resources['sleuth://causal-graph'] = _RegisteredResource(
      descriptor: const Resource(
        uri: 'sleuth://causal-graph',
        name: 'Sleuth Causal Graph',
        description:
            'Static rule set linking trigger stableIds to downstream effects.',
        mimeType: 'application/json',
      ),
      read: (b) => _causalGraph.read(),
    );
  }

  // Serializes writes to stdout so concurrent dispatches can't interleave
  // partial JSON lines. First write failure flips `_shuttingDown`.
  Future<void> _writeChain = Future<void>.value();
  Object? _firstWriteError;

  // In-flight dispatches drained by serve()'s finally before return.
  final Set<Future<void>> _pendingDispatches = <Future<void>>{};
  Completer<void>? _serveDone;
  bool _shuttingDown = false;

  /// Drive the server over stdio. Returns when stdin closes, when
  /// [shutdown] is called, or when a write failure trips fatal shutdown.
  /// Drains pending dispatches + the write chain before returning.
  Future<void> serve({
    Stream<List<int>>? input,
    IOSink? output,
  }) async {
    final codec = McpProtocolCodec();
    final out = output ?? stdout;
    final stream = input ?? stdin;
    final done = _serveDone = Completer<void>();
    final sub = codec.decode(stream).listen(
      (event) => _handleDecodeEvent(event, out, codec),
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      onError: (Object e) {
        _log('decode stream error: $e');
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: false,
    );
    try {
      await done.future;
    } finally {
      // Fire-and-forget cancel — `await sub.cancel()` blocks while the
      // upstream `await for` waits on a non-closed source.
      unawaited(sub.cancel());
      await Future.wait(List.of(_pendingDispatches));
      await _writeChain;
    }
  }

  void _handleDecodeEvent(Object event, IOSink out, McpProtocolCodec codec) {
    if (_shuttingDown) return;
    if (event is DecodeError) {
      if (event.id != null) {
        _writeLocked(
          out,
          codec,
          JsonRpcResponse.error(
            id: event.id,
            error: JsonRpcError(code: event.code, message: event.message),
          ),
        );
      }
      return;
    }
    if (event is! JsonRpcMessage) return;
    late Future<void> fut;
    fut = _dispatchAndWrite(event, out, codec).whenComplete(() {
      _pendingDispatches.remove(fut);
    });
    _pendingDispatches.add(fut);
  }

  /// Cooperative shutdown signal. Stops accepting new frames; `serve()`
  /// drains pending dispatches via its finally block. Callers await
  /// `server.serve(...)` to observe a fully-flushed pipe. Idempotent.
  void shutdown() {
    _shuttingDown = true;
    final done = _serveDone;
    if (done != null && !done.isCompleted) done.complete();
  }

  Future<void> _dispatchAndWrite(
    JsonRpcMessage event,
    IOSink out,
    McpProtocolCodec codec,
  ) async {
    final response = await _dispatch(event);
    if (response != null && !event.isNotification) {
      await _writeLocked(out, codec, response);
    }
  }

  Future<void> _writeLocked(
    IOSink out,
    McpProtocolCodec codec,
    JsonRpcResponse r,
  ) {
    final next = _writeChain.then((_) async {
      out.write(codec.encode(r));
      await out.flush();
    });
    _writeChain = next.catchError((Object e) {
      // First write failure trips shutdown; the per-call `next` still
      // surfaces the error to its caller.
      if (_firstWriteError == null) {
        _firstWriteError = e;
        _log('stdout write failed: $e — initiating shutdown');
        shutdown();
      }
    });
    return next;
  }

  void _log(String line) {
    final sink = _logger;
    if (sink != null) sink.add(line);
  }

  /// Direct request dispatch for unit tests. Returns `null` for
  /// notifications (no `id`).
  @visibleForTesting
  Future<JsonRpcResponse?> handleForTest(JsonRpcMessage msg) => _dispatch(msg);

  Future<JsonRpcResponse?> _dispatch(JsonRpcMessage msg) async {
    if (msg.method == 'initialize') {
      return _handleInitialize(msg);
    }
    if (msg.method == 'notifications/initialized') {
      return null; // notification, no response
    }
    if (msg.method == 'ping') {
      return msg.isNotification
          ? null
          : JsonRpcResponse.result(
              id: msg.id, result: const <String, Object?>{});
    }
    if (!_initialized) {
      return msg.isNotification
          ? null
          : JsonRpcResponse.error(
              id: msg.id,
              error: const JsonRpcError(
                code: JsonRpcError.serverNotInitialized,
                message: 'server not initialized — send initialize first',
              ),
            );
    }
    switch (msg.method) {
      case 'tools/list':
        return _handleToolsList(msg);
      case 'tools/call':
        return _handleToolsCall(msg);
      case 'resources/list':
        return _handleResourcesList(msg);
      case 'resources/read':
        return _handleResourcesRead(msg);
      default:
        return msg.isNotification
            ? null
            : JsonRpcResponse.error(
                id: msg.id,
                error: JsonRpcError(
                  code: JsonRpcError.methodNotFound,
                  message: 'unknown method: ${msg.method}',
                ),
              );
    }
  }

  JsonRpcResponse _handleInitialize(JsonRpcMessage msg) {
    final clientVersion = msg.params['protocolVersion'];
    String negotiated;
    if (clientVersion is String &&
        supportedMcpProtocolVersions.contains(clientVersion)) {
      negotiated = clientVersion;
    } else {
      negotiated = mcpProtocolVersion;
      if (clientVersion is String) {
        _log(
          'protocolVersion unsupported — client=$clientVersion '
          'server-pin=$mcpProtocolVersion (supported: $supportedMcpProtocolVersions)',
        );
      }
    }
    // Re-init may target a different session — drop cached resources.
    if (_initialized) {
      _encyclopedia.invalidate();
      _causalGraph.invalidate();
    }
    _initialized = true;
    return JsonRpcResponse.result(id: msg.id, result: {
      'protocolVersion': negotiated,
      'serverInfo': {
        'name': 'sleuth_mcp',
        'version': sleuthMcpVersion,
      },
      'capabilities': {
        'tools': const <String, Object?>{},
        'resources': const <String, Object?>{},
      },
    });
  }

  JsonRpcResponse _handleToolsList(JsonRpcMessage msg) {
    final list = _tools.values.map((t) => t.descriptor.toJson()).toList();
    return JsonRpcResponse.result(id: msg.id, result: {'tools': list});
  }

  Future<JsonRpcResponse> _handleToolsCall(JsonRpcMessage msg) async {
    final name = msg.params['name'];
    if (name is! String) {
      return JsonRpcResponse.result(
        id: msg.id,
        result: ToolCallResult.text(
          'missing "name" arg',
          isError: true,
        ).toJson(),
      );
    }
    final tool = _tools[name];
    if (tool == null) {
      return JsonRpcResponse.result(
        id: msg.id,
        result: ToolCallResult.text(
          'unknown_tool: $name',
          isError: true,
        ).toJson(),
      );
    }
    final rawArgs = msg.params['arguments'];
    Map<String, Object?> args;
    if (rawArgs == null) {
      args = const <String, Object?>{};
    } else if (rawArgs is Map<String, Object?>) {
      args = rawArgs;
    } else {
      return JsonRpcResponse.result(
        id: msg.id,
        result: ToolCallResult.text(
          'arguments must be a JSON object',
          isError: true,
        ).toJson(),
      );
    }
    final argError = _validateArgs(tool.descriptor.inputSchema, args);
    if (argError != null) {
      return JsonRpcResponse.result(
        id: msg.id,
        result: ToolCallResult.text(argError, isError: true).toJson(),
      );
    }
    try {
      final result = await tool.handler(bridge, args).timeout(_toolTimeout);
      final asResult = result is ToolCallResult
          ? result
          : ToolCallResult.text(jsonEncode(result));
      return JsonRpcResponse.result(id: msg.id, result: asResult.toJson());
    } on TimeoutException {
      // Drain the bridge so orphan vm_service requests don't accumulate;
      // client must re-invoke `connect` for the next tool call.
      try {
        await bridge.disconnect();
      } catch (e) {
        _log('post-timeout disconnect failed: $e');
      }
      return JsonRpcResponse.result(
        id: msg.id,
        result: ToolCallResult.text(
          'timeout_after_${_toolTimeout.inMilliseconds}ms — bridge disconnected; re-invoke connect',
          isError: true,
        ).toJson(),
      );
    } on SessionChangedException catch (e) {
      return JsonRpcResponse.result(
        id: msg.id,
        result: ToolCallResult.text(
          'session_changed baseline=${e.baseline} current=${e.current}',
          isError: true,
        ).toJson(),
      );
    } catch (e, st) {
      // Stack trace goes to the logger only — never to the MCP response.
      _log('tool "$name" threw: $e\n$st');
      return JsonRpcResponse.result(
        id: msg.id,
        result: ToolCallResult.text(
          'error: $e',
          isError: true,
        ).toJson(),
      );
    }
  }

  JsonRpcResponse _handleResourcesList(JsonRpcMessage msg) {
    final list = _resources.values.map((r) => r.descriptor.toJson()).toList();
    return JsonRpcResponse.result(id: msg.id, result: {'resources': list});
  }

  Future<JsonRpcResponse> _handleResourcesRead(JsonRpcMessage msg) async {
    final uri = msg.params['uri'];
    if (uri is! String) {
      return JsonRpcResponse.error(
        id: msg.id,
        error: const JsonRpcError(
          code: JsonRpcError.invalidParams,
          message: 'missing "uri" arg',
        ),
      );
    }
    final res = _resources[uri];
    if (res == null) {
      return JsonRpcResponse.error(
        id: msg.id,
        error: JsonRpcError(
          code: JsonRpcError.invalidParams,
          message: 'unknown resource: $uri',
        ),
      );
    }
    try {
      final content = await res.read(bridge).timeout(_toolTimeout);
      return JsonRpcResponse.result(id: msg.id, result: {
        'contents': [
          {
            'uri': uri,
            'mimeType': res.descriptor.mimeType,
            'text': jsonEncode(content),
          },
        ],
      });
    } on TimeoutException {
      try {
        await bridge.disconnect();
      } catch (e) {
        _log('post-timeout disconnect failed: $e');
      }
      return JsonRpcResponse.error(
        id: msg.id,
        error: JsonRpcError(
          code: JsonRpcError.internalError,
          message:
              'resource $uri timed out after ${_toolTimeout.inMilliseconds}ms',
        ),
      );
    } on SessionChangedException catch (e) {
      return JsonRpcResponse.error(
        id: msg.id,
        error: JsonRpcError(
          code: JsonRpcError.internalError,
          message:
              'session_changed baseline=${e.baseline} current=${e.current}',
        ),
      );
    } catch (e, st) {
      _log('resource $uri read threw: $e\n$st');
      return JsonRpcResponse.error(
        id: msg.id,
        error: JsonRpcError(
          code: JsonRpcError.internalError,
          message: 'resource read failed: $e',
        ),
      );
    }
  }

  String? _validateArgs(
    Map<String, Object?> schema,
    Map<String, Object?> args,
  ) {
    final required = schema['required'];
    if (required is List) {
      for (final r in required) {
        if (r is! String) continue;
        if (!args.containsKey(r)) {
          return 'missing_required_arg: $r';
        }
        if (args[r] == null) {
          return 'missing_required_arg: $r (null)';
        }
      }
    }
    final props = schema['properties'];
    if (props is Map<String, Object?>) {
      for (final entry in args.entries) {
        final spec = props[entry.key];
        if (spec is! Map<String, Object?>) continue;
        final actual = entry.value;
        if (actual == null) continue;
        final expectedType = spec['type'];
        final actualType = _jsonTypeOf(actual);
        if (expectedType is String && actualType != expectedType) {
          // JSON Schema `number` accepts integers.
          if (!(expectedType == 'number' && actualType == 'integer')) {
            return 'arg_type_mismatch: ${entry.key} expected $expectedType got $actualType';
          }
        }
        final enumValues = spec['enum'];
        if (enumValues is List && !enumValues.contains(actual)) {
          return 'arg_enum_violation: ${entry.key}=$actual not in $enumValues';
        }
        final minLength = spec['minLength'];
        if (minLength is int && actual is String && actual.length < minLength) {
          return 'arg_min_length_violation: ${entry.key} must be at least $minLength chars';
        }
      }
    }
    return null;
  }

  String _jsonTypeOf(Object value) {
    if (value is bool) return 'boolean';
    if (value is int) return 'integer';
    if (value is num) return 'number';
    if (value is String) return 'string';
    if (value is List) return 'array';
    if (value is Map) return 'object';
    return 'unknown';
  }
}
