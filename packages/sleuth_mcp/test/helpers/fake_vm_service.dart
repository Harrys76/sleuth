import 'dart:async';
import 'dart:convert';

import 'package:vm_service/vm_service.dart' as vm;

/// Answers one extension call with the envelope the app would return.
typedef FakeExtensionHandler =
    FutureOr<Map<String, Object?>> Function(Map<String, Object?> params);

/// Answers one `getObject` call with the object's JSON.
typedef FakeObjectHandler =
    Map<String, Object?> Function(Map<String, Object?> params);

/// One isolate of a [FakeVmServiceBackend].
class FakeIsolate {
  FakeIsolate(this.id, this.name);

  final String id;
  final String name;

  /// Registered extensions, in registration order.
  final Map<String, FakeExtensionHandler> extensions = {};

  Map<String, Object?> get ref => {
    'type': '@Isolate',
    'id': id,
    'name': name,
    'number': id.split('/').last,
    'isSystemIsolate': false,
  };
}

/// An in-memory VM service for `RealVmBridge` tests.
///
/// It speaks the JSON-RPC wire protocol to real `vm.VmService` clients, so
/// the client's own parsing runs as it does against a device: a call to an
/// isolate that no longer exists returns a `Collected` sentinel, an
/// extension the isolate has not registered returns method-not-found, and
/// stream events arrive as `streamNotify` messages.
class FakeVmServiceBackend {
  final List<FakeIsolate> _isolates = [];
  final List<_FakeClient> _clients = [];

  /// Answers for `getObject`, keyed by object id.
  final Map<String, FakeObjectHandler> objects = {};

  /// Every request the backend received, as `method` or
  /// `method isolateId`, in order.
  final List<String> requests = [];

  final Map<String, List<Completer<void>>> _holds = {};
  final Map<String, List<Map<String, Object?>>> _failures = {};

  /// How many clients [connect] opened.
  int get connectCount => _clients.length;

  /// The live isolates, in VM order.
  List<FakeIsolate> get isolates => List.unmodifiable(_isolates);

  /// Opens a new client connection, as `vmServiceConnectUri` does.
  Future<vm.VmService> connect([String? wsUri]) async {
    final client = _FakeClient(this);
    _clients.add(client);
    return client.service;
  }

  /// Starts an isolate. Clients that listen to the `Isolate` stream see
  /// `IsolateStart` and `IsolateRunnable`.
  FakeIsolate addIsolate(String id, {String name = 'main'}) {
    final isolate = FakeIsolate(id, name);
    _isolates.add(isolate);
    for (final kind in ['IsolateStart', 'IsolateRunnable']) {
      _notify('Isolate', {
        'type': 'Event',
        'kind': kind,
        'isolate': isolate.ref,
        'timestamp': 1,
      });
    }
    return isolate;
  }

  /// Ends an isolate, as a hot restart ends the old main isolate.
  void removeIsolate(String id) {
    final index = _isolates.indexWhere((i) => i.id == id);
    if (index < 0) return;
    final isolate = _isolates.removeAt(index);
    _notify('Isolate', {
      'type': 'Event',
      'kind': 'IsolateExit',
      'isolate': isolate.ref,
      'timestamp': 1,
    });
  }

  /// Registers [method] on [isolateId]. Clients that listen to the
  /// `Isolate` stream see `ServiceExtensionAdded`.
  void registerExtension(
    String isolateId,
    String method,
    FakeExtensionHandler handler,
  ) {
    final isolate = _isolates.firstWhere((i) => i.id == isolateId);
    isolate.extensions[method] = handler;
    _notify('Isolate', {
      'type': 'Event',
      'kind': 'ServiceExtensionAdded',
      'isolate': isolate.ref,
      'extensionRPC': method,
      'timestamp': 1,
    });
  }

  /// Holds the next answer to [method] until the returned completer
  /// completes.
  Completer<void> hold(String method) {
    final gate = Completer<void>();
    (_holds[method] ??= []).add(gate);
    return gate;
  }

  /// Answers the next call to [method] with this JSON-RPC error.
  void failNext(String method, {required int code, required String message}) {
    (_failures[method] ??= []).add({'code': code, 'message': message});
  }

  /// Sends [event] on [streamId] to every client that listens to it.
  void sendEvent(String streamId, Map<String, Object?> event) =>
      _notify(streamId, event);

  void _notify(String streamId, Map<String, Object?> event) {
    for (final client in _clients) {
      if (!client.streams.contains(streamId)) continue;
      client.send({
        'jsonrpc': '2.0',
        'method': 'streamNotify',
        'params': {'streamId': streamId, 'event': event},
      });
    }
  }

  FakeIsolate? _isolate(Object? id) {
    for (final isolate in _isolates) {
      if (isolate.id == id) return isolate;
    }
    return null;
  }

  static const Map<String, Object?> _collected = {
    'type': 'Sentinel',
    'kind': 'Collected',
    'valueAsString': '<collected>',
  };

  Future<Map<String, Object?>> _answer(
    _FakeClient client,
    String method,
    Map<String, Object?> params,
  ) async {
    final isolateId = params['isolateId'];
    requests.add(isolateId == null ? method : '$method $isolateId');
    final holds = _holds[method];
    if (holds != null && holds.isNotEmpty) await holds.removeAt(0).future;
    final failures = _failures[method];
    if (failures != null && failures.isNotEmpty) {
      return {'error': failures.removeAt(0)};
    }
    switch (method) {
      case 'getVM':
        return {
          'result': {
            'type': 'VM',
            'name': 'vm',
            'isolates': [for (final isolate in _isolates) isolate.ref],
          },
        };
      case 'getIsolate':
        final isolate = _isolate(isolateId);
        if (isolate == null) return {'result': _collected};
        return {
          'result': {
            ...isolate.ref,
            'type': 'Isolate',
            'runnable': true,
            'extensionRPCs': isolate.extensions.keys.toList(),
          },
        };
      case 'streamListen':
        final streamId = params['streamId'] as String;
        if (!client.streams.add(streamId)) {
          return {
            'error': {'code': 103, 'message': 'Stream already subscribed'},
          };
        }
        return {
          'result': {'type': 'Success'},
        };
      case 'streamCancel':
        client.streams.remove(params['streamId']);
        return {
          'result': {'type': 'Success'},
        };
      case 'getObject':
        if (_isolate(isolateId) == null) return {'result': _collected};
        final handler = objects[params['objectId']];
        if (handler == null) {
          return {
            'result': {
              'type': 'Sentinel',
              'kind': 'Expired',
              'valueAsString': '<expired>',
            },
          };
        }
        return {'result': handler(params)};
    }
    if (method.startsWith('ext.')) {
      final isolate = _isolate(isolateId);
      if (isolate == null) return {'result': _collected};
      final handler = isolate.extensions[method];
      if (handler == null) {
        return {
          'error': {'code': -32601, 'message': 'Method not found'},
        };
      }
      return {'result': await handler(params)};
    }
    return {
      'error': {'code': -32601, 'message': 'Method not found: $method'},
    };
  }
}

class _FakeClient {
  _FakeClient(this.backend) {
    service = vm.VmService(_toClient.stream, _onRequest);
  }

  final FakeVmServiceBackend backend;
  final StreamController<String> _toClient = StreamController<String>();
  late final vm.VmService service;
  final Set<String> streams = {};

  void send(Map<String, Object?> message) {
    if (_toClient.isClosed) return;
    _toClient.add(jsonEncode(message));
  }

  void _onRequest(String message) {
    final request = jsonDecode(message) as Map<String, Object?>;
    final id = request['id'];
    final method = request['method'] as String;
    final params = Map<String, Object?>.from(
      (request['params'] as Map?) ?? const {},
    );
    // Answer in a later event, as a socket would.
    Timer.run(() async {
      final answer = await backend._answer(this, method, params);
      send({'jsonrpc': '2.0', 'id': id, ...answer});
    });
  }
}

/// A `Logging` event whose message the VM service cut to [shown], for the
/// string object [messageId] of [length] characters.
Map<String, Object?> fakeCutLogEvent({
  required String isolateId,
  required String messageId,
  required String shown,
  required int length,
}) => {
  'type': 'Event',
  'kind': 'Logging',
  'isolate': {
    'type': '@Isolate',
    'id': isolateId,
    'name': 'main',
    'number': '1',
  },
  'timestamp': 1700000000000,
  'logRecord': {
    'type': 'LogRecord',
    'message': {
      'type': '@Instance',
      'kind': 'String',
      'id': messageId,
      'valueAsString': shown,
      'valueAsStringIsTruncated': true,
      'length': length,
    },
    'time': 1700000000000,
    'level': 800,
    'sequenceNumber': 1,
  },
};

/// A `getObject` answer for a string of [full], read with the request's
/// `count` the way the VM reads it: the first `count` characters, with
/// `length` the whole string's length.
FakeObjectHandler fakeStringObject(String id, String full) => (params) {
  final count = params['count'] as int?;
  final shown = count != null && count < full.length
      ? full.substring(0, count)
      : full;
  return {
    'type': 'Instance',
    'id': id,
    'kind': 'String',
    'class': {'type': '@Class', 'id': 'classes/1', 'name': '_OneByteString'},
    'identityHashCode': 0,
    'length': full.length,
    if (count != null) 'count': shown.length,
    'valueAsString': shown,
    if (shown.length < full.length) 'valueAsStringIsTruncated': true,
  };
};
