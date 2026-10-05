import '../models/frame_verdict.dart';
import '../vm/connection_mode.dart';

/// The app's state when an AI chat message is sent, rendered as the
/// "## Session" section of the system prompt.
///
/// Holds no issue titles beyond what the prompt already carries: the
/// hidden issues contribute a count only, and the route is the one the
/// issues already name.
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

  /// Presented frames in the last second.
  final double? actualFps;

  /// Frame-time derived throughput.
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

  /// Longest verdict reason carried into the prompt.
  static const int maxReasonLength = 160;

  int get issueCount => criticalCount + warningCount + okCount;

  static final RegExp _whitespace = RegExp(r'\s+');

  /// The first line of a verdict [reason], whitespace collapsed, cut
  /// before any `Related:` part: the related issue's title may be one
  /// the user hid.
  static String summarizeReason(String reason) {
    var line = reason.trimLeft().split('\n').first;
    final related = line.indexOf('Related:');
    if (related >= 0) line = line.substring(0, related);
    return line.replaceAll(_whitespace, ' ').trim();
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
      route ?? 'no route yet',
      if (_shownFps != null) '$_shownFps FPS',
      '$issueCount ${issueCount == 1 ? 'issue' : 'issues'}',
    ];
    return 'Context: ${parts.join(' · ')}';
  }

  /// The session lines, one fact per line, without a heading.
  String render() {
    final buf = StringBuffer();
    buf.writeln('Current route: ${route ?? 'unknown'}');
    if (actualFps != null || throughputFps != null) {
      final rates = <String>[
        if (actualFps != null) '${actualFps!.round()} FPS presented',
        if (throughputFps != null) '${throughputFps!.round()} FPS throughput',
      ];
      final target = fpsTarget == null ? '' : ' (target $fpsTarget)';
      buf.writeln('Frame rate: ${rates.join(', ')}$target');
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
