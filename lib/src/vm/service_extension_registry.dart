import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

import '../controller/sleuth_controller.dart';
import 'service_extension_handlers.dart';

/// Binds `ext.sleuth.*` extensions to `dart:developer`.
///
/// Process-wide singleton — `registerExtension` throws on duplicate name
/// and has no unregister API. Subsequent constructions swap a static
/// `WeakReference<SleuthController>`; the dispatcher reads the weak ref
/// at call time, so a disposed controller produces `{disposed: true}`
/// until a fresh registry binds.
class ServiceExtensionRegistry {
  ServiceExtensionRegistry(this._controller);

  static const Map<String, ExtensionHandler> _handlers = {
    'ext.sleuth.snapshot': extSnapshotHandler,
    'ext.sleuth.issues': extIssuesHandler,
    'ext.sleuth.routeHealth': extRouteHealthHandler,
    'ext.sleuth.explain': extExplainHandler,
    'ext.sleuth.encyclopedia': extEncyclopediaHandler,
    'ext.sleuth.causalGraph': extCausalGraphHandler,
    'ext.sleuth.diagnose': extDiagnoseHandler,
  };

  static final Set<String> _bound = <String>{};
  static WeakReference<SleuthController>? _currentController;

  /// Test-only bind substitute for `developer.registerExtension`.
  @visibleForTesting
  static void Function(
    String name,
    Future<developer.ServiceExtensionResponse> Function(
      String method,
      Map<String, String> args,
    ) handler,
  )? registerFnForTest;

  @visibleForTesting
  static void resetForTest() {
    _bound.clear();
    _currentController = null;
  }

  static List<String> get registeredNames =>
      List<String>.unmodifiable(_handlers.keys);

  /// Names advertised but not yet bound (partial-registration recovery).
  /// Surfaced through `ext.sleuth.diagnose` so a sidecar can warn its
  /// operator when the live surface is degraded.
  static List<String> get unboundNames => _handlers.keys
      .where((name) => !_bound.contains(name))
      .toList(growable: false);

  final SleuthController _controller;

  /// Bind the active controller. Release-mode is a no-op. Retries only
  /// names that have never bound (`registerExtension` throws on duplicate).
  void registerAll() {
    if (kReleaseMode) return;
    _currentController = WeakReference(_controller);
    final registerFn = registerFnForTest ?? developer.registerExtension;
    for (final name in _handlers.keys) {
      if (_bound.contains(name)) continue;
      try {
        registerFn(name, _dispatch);
        _bound.add(name);
      } catch (e, st) {
        developer.log(
          'ServiceExtensionRegistry: registerExtension($name) failed',
          error: e,
          stackTrace: st,
        );
      }
    }
  }

  /// Clear the static weak-ref slot if it still points at this controller.
  /// Dispatch will return `{disposed: true}` until a fresh registry binds.
  void markDisposed() {
    final current = _currentController?.target;
    if (current == null || identical(current, _controller)) {
      _currentController = null;
    }
  }

  static Future<developer.ServiceExtensionResponse> _dispatch(
    String method,
    Map<String, String> args,
  ) async {
    final controller = _currentController?.target;
    if (controller == null) {
      return developer.ServiceExtensionResponse.result(
          jsonEncode(<String, Object?>{
        'connectionMode': 'disconnected',
        'schemaVersion': kMcpEnvelopeSchemaVersion,
        'disposed': true,
        'method': method,
      }));
    }
    final handler = _handlers[method];
    if (handler == null) {
      return developer.ServiceExtensionResponse.error(
        developer.ServiceExtensionResponse.invalidParams,
        jsonEncode(<String, Object?>{
          'error': 'unknown_method',
          'method': method,
        }),
      );
    }
    try {
      final payload = await handler(controller, args);
      return developer.ServiceExtensionResponse.result(jsonEncode(payload));
    } catch (e, st) {
      // Dispose-race surface: weak ref cleared between entry and throw.
      if (_currentController?.target == null) {
        return developer.ServiceExtensionResponse.result(
            jsonEncode(<String, Object?>{
          'connectionMode': 'disconnected',
          'schemaVersion': kMcpEnvelopeSchemaVersion,
          'disposed': true,
          'method': method,
          'error': '$e',
        }));
      }
      return developer.ServiceExtensionResponse.result(jsonEncode(
        envelopeError(
          controller: controller,
          error: '$e',
          stack: '$st',
          extra: <String, Object?>{'method': method},
        ),
      ));
    }
  }
}
