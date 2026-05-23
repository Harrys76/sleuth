import 'dart:convert';
import 'dart:io';

import 'package:sleuth_mcp/sleuth_mcp.dart';
import 'package:test/test.dart';

/// Walk up from the test file (or `Directory.current`) until a
/// directory containing `mcp_tool_schema.json` is found. Mirrors the
/// resolution pattern used by `mcp_tool_schema_audit_test.dart`.
File _resolveToolSchemaFile() {
  for (final start in [
    Directory.current,
    File.fromUri(Platform.script).parent,
  ]) {
    var dir = start;
    for (var i = 0; i < 8; i++) {
      final candidate =
          File('${dir.path}/packages/sleuth_mcp/doc/mcp_tool_schema.json');
      final inSidecar = File('${dir.path}/doc/mcp_tool_schema.json');
      if (candidate.existsSync()) return candidate;
      if (inSidecar.existsSync() &&
          File('${dir.path}/pubspec.yaml').existsSync() &&
          File('${dir.path}/pubspec.yaml')
              .readAsStringSync()
              .contains('name: sleuth_mcp')) {
        return inSidecar;
      }
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
  }
  throw StateError('mcp_tool_schema.json not found from cwd or test script');
}

void main() {
  test('every IosAttachErrorKind maps to a documented attach_app errors[].code',
      () {
    final file = _resolveToolSchemaFile();
    final schema = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    final tools = schema['tools'] as Map<String, Object?>;
    final attachApp = tools['attach_app'] as Map<String, Object?>;
    final errors = attachApp['errors'] as List;
    final codes = errors
        .whereType<Map<String, Object?>>()
        .map((e) => e['code'] as String)
        .toSet();

    // Walk all enum values exported via the public surface. Any
    // future addition to `IosAttachErrorKind` must be reflected in
    // the schema; the test fails loudly otherwise so the contract
    // doesn't drift silently.
    for (final kind in IosAttachErrorKind.values) {
      // Translate the dart enum name to the public typed-error name
      // by matching against what the tool handler returns — we
      // don't import the private mapper, so build the expected name
      // set from the schema and prove each kind has a counterpart.
      // The mapping table below mirrors `_iosErrorKindToTypedName`
      // in `tools.dart`; updating either side without the other
      // trips this assertion.
      final expected = _expectedTypedName[kind];
      expect(expected, isNotNull,
          reason:
              'IosAttachErrorKind.${kind.name} has no entry in test mapping '
              '— update both _iosErrorKindToTypedName and this registry');
      expect(codes, contains(expected),
          reason: 'IosAttachErrorKind.${kind.name} maps to "$expected" but the '
              'schema does not document that error code in attach_app.errors');
    }

    // Documented codes must map to an enum value OR be in the
    // tool-layer-only allowlist below.
    //
    // MAINTENANCE: three synced touchpoints per typed error —
    // (1) production mapper / `_iosErrorEnvelope` call site,
    // (2) schema `doc/mcp_tool_schema.{json,md}`, (3) this allowlist.
    // Audit catches single-side drift; rule is "change two, change three".
    const toolLayerOnly = {
      'ios_missing_bundle',
      'ios_ambiguous_args',
      'ios_invalid_transport',
      'ios_vmservice_busy',
      'ios_vmservice_unreachable',
      'attach_in_progress',
      'session_missing',
      'version_skew_major',
      'version_skew_unknown',
      'daemon_failure',
    };
    final fromKinds = _expectedTypedName.values.toSet();
    for (final code in codes) {
      expect(fromKinds.contains(code) || toolLayerOnly.contains(code), isTrue,
          reason: 'attach_app documents error code "$code" but no '
              'IosAttachErrorKind maps to it AND it is not in the '
              'tool-layer-only allowlist — orphaned documentation');
    }
  });
}

/// Mirror of `_iosErrorKindToTypedName` in
/// `packages/sleuth_mcp/lib/src/tools/tools.dart`. Kept here so the
/// registry-sync test can detect any divergence between the
/// production mapper and the schema's `errors[].code` list.
const _expectedTypedName = <IosAttachErrorKind, String>{
  IosAttachErrorKind.missingTool: 'ios_missing_tool',
  IosAttachErrorKind.launchFailed: 'ios_launch_failed',
  IosAttachErrorKind.bonjourTimeout: 'ios_bonjour_timeout',
  IosAttachErrorKind.ambiguousPairings: 'ios_ambiguous_pairings',
  IosAttachErrorKind.noMatchingAuth: 'ios_no_matching_auth',
  IosAttachErrorKind.iproxyFailedSpawn: 'ios_iproxy_failed',
  IosAttachErrorKind.iproxyReadinessFailed: 'ios_iproxy_failed',
  IosAttachErrorKind.cancelled: 'ios_cancelled',
};
