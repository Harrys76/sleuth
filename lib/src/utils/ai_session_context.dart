import '../models/frame_verdict.dart';
import '../vm/connection_mode.dart';

/// The app's state when an AI chat message is sent, rendered as the
/// "## Session" section of the system prompt.
///
/// Holds no issue titles beyond what the prompt already carries: the
/// hidden issues contribute a count only, and the route is the one the
/// issues already name, without its query or fragment ([promptRoute]).
class AiSessionContext {
  const AiSessionContext({
    this.route,
    this.actualFps,
    this.throughputFps,
    this.fpsTarget,
    this.verdictPhase,
    this.verdictReason,
    this.verdictMode,
    this.criticalCount = 0,
    this.warningCount = 0,
    this.okCount = 0,
    this.hiddenCount = 0,
    this.isDebugMode = false,
    this.connectionMode,
    this.platform,
  });

  /// Route of the active session, or null before the first route.
  final String? route;

  /// Presented frames in the last second, the overlay's own frames
  /// included.
  final double? actualFps;

  /// Frame-time derived throughput over the recent frames, the overlay's
  /// own frames included.
  final double? throughputFps;

  /// Configured frame-rate target.
  final int? fpsTarget;

  /// Suspected phase of the latest frame verdict.
  final PipelinePhase? verdictPhase;

  /// Reason of the latest frame verdict.
  final String? verdictReason;

  /// `correlated`, `full` or `basic`: how the latest verdict was built.
  final String? verdictMode;

  /// Active issues by severity.
  final int criticalCount;
  final int warningCount;
  final int okCount;

  /// Issues the user hid from the overlay.
  final int hiddenCount;

  /// Whether the app runs a debug build (counts and timings inflate).
  final bool isDebugMode;

  /// How Sleuth is reading the app.
  final ConnectionMode? connectionMode;

  /// Target platform name, e.g. `iOS` or `android`.
  final String? platform;

  /// Longest verdict reason carried into the prompt; fits a full verdict's
  /// phase line with every timing.
  static const int maxReasonLength = 240;

  int get issueCount => criticalCount + warningCount + okCount;

  static final RegExp _whitespace = RegExp(r'\s+');

  static final RegExp _queryOrFragment = RegExp('[?#]');

  /// [route] without its query (`?…`) or fragment (`#…`): a deep link's
  /// parameters can carry ids or tokens the prompt has no use for. A
  /// route that is all query reads as `/`.
  static String promptRoute(String route) {
    final end = route.indexOf(_queryOrFragment);
    if (end < 0) return route;
    final path = route.substring(0, end);
    return path.isEmpty ? '/' : path;
  }

  /// A verdict [reason] on one line, whitespace collapsed, cut before any
  /// `Related:` part: the related issue's title may be one the user hid.
  ///
  /// Keeps the first line and the indented timing lines under it (a full
  /// or correlated verdict lists each phase's time there), e.g.
  /// `Suspected bottleneck: BUILD (build: 22.0ms, layout: 1.2ms)`. The
  /// first line that is not indented ends the summary.
  static String summarizeReason(String reason) {
    final lines = reason.trimLeft().split('\n');
    final parts = <String>[];
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i];
      if (i > 0 && !line.startsWith(' ') && !line.startsWith('\t')) break;
      final related = line.indexOf('Related:');
      if (related >= 0) line = line.substring(0, related);
      line = line.replaceAll(_whitespace, ' ').trim();
      if (line.isNotEmpty) parts.add(line);
      if (related >= 0) break;
    }
    if (parts.length < 2) return parts.isEmpty ? '' : parts.first;
    return '${parts.first} (${parts.skip(1).join(', ')})';
  }

  /// FPS shown in the caption: throughput capped at the target, else the
  /// presented rate.
  int? get _shownFps {
    final fps = throughputFps ?? actualFps;
    if (fps == null) return null;
    final target = fpsTarget;
    final capped = target != null && fps > target ? target.toDouble() : fps;
    return capped.round();
  }

  /// One line telling the user what the next message carries, e.g.
  /// `Context: /home · 58 FPS · 12 issues`.
  String caption() {
    final parts = <String>[
      route == null ? 'no route yet' : promptRoute(route!),
      if (_shownFps != null) '$_shownFps FPS',
      '$issueCount ${issueCount == 1 ? 'issue' : 'issues'}',
    ];
    return 'Context: ${parts.join(' · ')}';
  }

  /// The session lines, one fact per line, without a heading.
  String render() {
    final buf = StringBuffer();
    buf.writeln(
      'Current route: ${route == null ? 'unknown' : promptRoute(route!)}',
    );
    if (actualFps != null || throughputFps != null) {
      final rates = <String>[
        if (actualFps != null) '${actualFps!.round()} FPS presented',
        if (throughputFps != null) '${throughputFps!.round()} FPS throughput',
      ];
      final target = fpsTarget == null ? '' : ' (target $fpsTarget)';
      // Both rates count every frame, the overlay's own included, and the
      // app may sit idle behind the chat: the label keeps either rate from
      // reading as the app's own.
      buf.writeln(
        'Frame rate (whole app, overlay open): ${rates.join(', ')}$target',
      );
    }
    if (verdictPhase != null) {
      final reason = verdictReason == null
          ? ''
          : summarizeReason(verdictReason!);
      final shortReason = reason.isEmpty
          ? ''
          : ': ${reason.length > maxReasonLength ? '${reason.substring(0, maxReasonLength)}…' : reason}';
      final mode = verdictMode == null ? '' : ' [$verdictMode]';
      buf.writeln(
        'Latest frame verdict: ${verdictPhase!.name}$shortReason$mode',
      );
    }
    buf.writeln(
      'Active issues: $issueCount ($criticalCount critical, '
      '$warningCount warning, $okCount ok)',
    );
    buf.writeln('Hidden by user: $hiddenCount');
    buf.writeln(
      'Build: ${isDebugMode ? 'debug (timings inflated)' : 'profile or release'}',
    );
    if (connectionMode != null) {
      buf.writeln('Connection: ${connectionMode!.name}');
    }
    if (platform != null) buf.writeln('Platform: $platform');
    return buf.toString();
  }
}
