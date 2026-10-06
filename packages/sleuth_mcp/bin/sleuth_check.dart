import 'dart:io';

import 'package:sleuth_mcp/sleuth_mcp.dart';

/// One-shot CI gate. Connects, calls `ext.sleuth.snapshot`, evaluates
/// budgets, prints report. Exits 0 on pass, 1 on a budget violation, 2
/// when the check could not run (connect failure, version refusal,
/// malformed snapshot, or `coverage_degraded`: the app has no VM service
/// link, so the VM-only detectors never ran), and 64 on a bad command
/// line such as a missing `--uri`. It is not an MCP server; it is built for
/// CI shell scripts.
Future<void> main(List<String> argv) async {
  exitCode = await runCheckCommand(argv);
}
