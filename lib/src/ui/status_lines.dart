import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../controller/coverage_report.dart';
import '../controller/run_state.dart';
import 'focus_ink_well.dart';
import 'sleuth_theme.dart';
import 'text_scale_clamp.dart';

/// Which status line the overlay shows.
enum SleuthStatusKind {
  /// The first VM connect attempt has not resolved.
  starting,

  /// Inside the frame-timing warm-up.
  warmingUp,

  /// No VM link this session: the checks that need it are off.
  noVm,

  /// Running with the VM, no issues reported.
  clean,

  /// The VM link was up and dropped; background attempts are running.
  vmLost,

  /// The VM link dropped and the background attempts are used up.
  stoppedRetrying,
}

/// The status line for [run]. A VM link that is down outranks warm-up,
/// since it decides which checks run at all.
SleuthStatusKind statusKindOf(SleuthRunState run) {
  if (run.phase == SleuthRunPhase.starting) return SleuthStatusKind.starting;
  if (!run.vmConnected) {
    if (!run.everConnected) return SleuthStatusKind.noVm;
    return run.stoppedRetrying
        ? SleuthStatusKind.stoppedRetrying
        : SleuthStatusKind.vmLost;
  }
  return run.phase == SleuthRunPhase.warmingUp
      ? SleuthStatusKind.warmingUp
      : SleuthStatusKind.clean;
}

/// The status row's words in place of the chips when no card is counted.
String statusRowLabel(SleuthStatusKind kind) => switch (kind) {
  SleuthStatusKind.starting => 'Starting',
  SleuthStatusKind.warmingUp => 'Warming up',
  SleuthStatusKind.noVm => 'No issues from the checks that ran',
  SleuthStatusKind.clean => 'No issues',
  SleuthStatusKind.vmLost || SleuthStatusKind.stoppedRetrying => 'VM link lost',
};

/// The command that starts an app with the VM link Sleuth needs.
const String sleuthRunCommand = 'flutter run --profile --no-dds';

/// The status line in the issue list: what the session is doing and how
/// much of it is checked, with the counts from [coverage].
///
/// For a screen reader it is a live region whose label names the state
/// and whose value holds the numbers, so it announces once per state
/// change and the warm-up countdown does not repeat the label.
class SleuthStatusBox extends StatefulWidget {
  const SleuthStatusBox({
    super.key,
    required this.kind,
    required this.run,
    required this.coverage,
    this.initializedAt,
    this.warmupDuration = Duration.zero,
    this.onCopyCommand,
    this.onReconnect,
    this.reconnecting = false,
  });

  final SleuthStatusKind kind;
  final SleuthRunState run;
  final CoverageReport coverage;

  /// When the session started, for the warm-up countdown.
  final DateTime? initializedAt;
  final Duration warmupDuration;

  /// Copies the run command; null leaves out Copy.
  final VoidCallback? onCopyCommand;

  /// Asks for a manual reconnect; null leaves out the button.
  final VoidCallback? onReconnect;

  /// A manual reconnect is running.
  final bool reconnecting;

  @override
  State<SleuthStatusBox> createState() => _SleuthStatusBoxState();
}

class _SleuthStatusBoxState extends State<SleuthStatusBox> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _syncTick();
  }

  @override
  void didUpdateWidget(covariant SleuthStatusBox oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTick();
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  /// A one-second tick runs only while warming up, for the countdown.
  void _syncTick() {
    if (widget.kind == SleuthStatusKind.warmingUp) {
      _tick ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else {
      _tick?.cancel();
      _tick = null;
    }
  }

  /// Whole seconds of warm-up passed, and the warm-up in seconds.
  (int, int) _warmup() {
    final total = math.max(1, widget.warmupDuration.inMilliseconds);
    final start = widget.initializedAt;
    final passed = start == null
        ? 0
        : DateTime.now().difference(start).inMilliseconds.clamp(0, total);
    return ((passed / 1000).floor(), (total / 1000).ceil());
  }

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);
    final c = widget.coverage;
    final off = c.count(CheckCoverage.needsVm);
    final partly = c.count(CheckCoverage.partial);
    final on = c.count(CheckCoverage.on);
    final optIn = c.count(CheckCoverage.optInOff);
    final disabled = c.count(CheckCoverage.disabled);
    final run = widget.run;
    final attempt = run.reconnectAttempt;

    final String state;
    final String? numbers;
    final String title;
    final String body;
    final (Color, Color) tone;
    switch (widget.kind) {
      case SleuthStatusKind.starting:
        state = 'Starting';
        numbers = null;
        title = 'Starting.';
        body = 'Sleuth is connecting to the Dart VM service.';
        tone = (theme.sectionBackground, theme.textSecondary);
      case SleuthStatusKind.warmingUp:
        final (passed, total) = _warmup();
        state = 'Warming up';
        numbers = '$passed of $total seconds';
        title = 'Warming up ($passed of $total s).';
        body =
            'Some checks have not reported yet, so an empty list does not '
            'mean healthy.';
        tone = (theme.sectionBackground, theme.textSecondary);
      case SleuthStatusKind.noVm:
        final counts = [
          '$off ${off == 1 ? 'check' : 'checks'} off',
          if (partly > 0) '$partly partly off',
        ].join(', ');
        state = 'No VM link';
        numbers = counts;
        title = 'No VM link: $counts.';
        body = 'They need the Dart VM service. Run the app with:';
        tone = (theme.bannerWarningBg, theme.bannerWarningText);
      case SleuthStatusKind.clean:
        final counts = [
          '$on ${on == 1 ? 'check' : 'checks'} on',
          if (optIn > 0) '$optIn opt-in ${optIn == 1 ? 'check' : 'checks'} off',
          if (disabled > 0) '$disabled turned off in the config',
        ].join(', ');
        state = 'No issues found';
        numbers = counts;
        title = 'No issues found.';
        body = 'VM link on; $counts.';
        tone = (theme.bannerSuccessBg, theme.bannerSuccessText);
      case SleuthStatusKind.vmLost:
        state = 'VM link lost';
        numbers = attempt == null
            ? null
            : 'Reconnecting, attempt $attempt of ${run.maxReconnectAttempts}';
        title = 'VM link lost.';
        final trying = attempt == null
            ? 'Reconnecting'
            : 'Reconnecting, attempt $attempt of ${run.maxReconnectAttempts}';
        body = '$trying. Checks that need the VM are paused until it is back.';
        tone = (theme.bannerWarningBg, theme.bannerWarningText);
      case SleuthStatusKind.stoppedRetrying:
        state = 'VM link lost';
        numbers = 'Stopped retrying';
        title = 'VM link lost.';
        body =
            'Sleuth stopped retrying. Checks that need the VM are paused '
            'until it is back.';
        tone = (theme.bannerWarningBg, theme.bannerWarningText);
    }
    final (fill, ink) = tone;
    final textStyle = TextStyle(
      color: ink,
      fontSize: theme.fontMd,
      height: 1.45,
    );
    final (passed, total) = _warmup();
    return Semantics(
      container: true,
      liveRegion: true,
      label: state,
      value: numbers,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: theme.spacingMd,
          vertical: theme.spacingSm,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(theme.radiusXl),
          ),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              theme.spacingLg,
              10,
              theme.spacingLg,
              10,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // The label and value carry the state; the text adds the
                // explanation.
                ExcludeSemantics(
                  child: Text(
                    title,
                    style: textStyle.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                // Its own node, so the live region's label stays the state.
                Semantics(container: true, child: Text(body, style: textStyle)),
                if (widget.kind == SleuthStatusKind.warmingUp)
                  Padding(
                    padding: EdgeInsets.only(top: theme.spacingMd),
                    child: ExcludeSemantics(
                      child: SizedBox(
                        height: 4,
                        child: CustomPaint(
                          painter: _ProgressPainter(
                            fraction: passed / total,
                            track: theme.border,
                            fill: theme.checkboxActive,
                          ),
                        ),
                      ),
                    ),
                  ),
                if (widget.kind == SleuthStatusKind.noVm)
                  Padding(
                    padding: EdgeInsets.only(top: theme.spacingMd),
                    child: _CommandLine(onCopy: widget.onCopyCommand),
                  ),
                if (widget.onReconnect != null)
                  Padding(
                    padding: EdgeInsets.only(top: theme.spacingSm),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: _ReconnectButton(
                        busy: widget.reconnecting,
                        onTap: widget.onReconnect!,
                        color: ink,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ProgressPainter extends CustomPainter {
  _ProgressPainter({
    required this.fraction,
    required this.track,
    required this.fill,
  });

  final double fraction;
  final Color track;
  final Color fill;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Radius.circular(size.height / 2);
    canvas.drawRRect(
      RRect.fromLTRBR(0, 0, size.width, size.height, r),
      Paint()..color = track,
    );
    final end = size.width * fraction.clamp(0.0, 1.0);
    if (end > 0) {
      canvas.drawRRect(
        RRect.fromLTRBR(0, 0, end, size.height, r),
        Paint()..color = fill,
      );
    }
  }

  @override
  bool shouldRepaint(_ProgressPainter old) =>
      old.fraction != fraction || old.track != track || old.fill != fill;
}

/// The run command in a monospace line, with Copy.
class _CommandLine extends StatelessWidget {
  const _CommandLine({this.onCopy});

  final VoidCallback? onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);
    final radius = BorderRadius.circular(theme.radiusMd);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.fixHintBackground,
        borderRadius: radius,
        border: Border.all(color: theme.cardDivider),
      ),
      child: Row(
        children: [
          Expanded(
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: theme.spacingMd,
                vertical: theme.spacingSm,
              ),
              child: Text(
                sleuthRunCommand,
                style: TextStyle(
                  color: theme.textPrimary,
                  fontSize: theme.fontSm,
                  fontFamily: 'monospace',
                  fontFamilyFallback: const ['Menlo', 'Courier'],
                ),
              ),
            ),
          ),
          if (onCopy != null)
            Semantics(
              container: true,
              button: true,
              label: 'Copy command',
              onTap: onCopy,
              excludeSemantics: true,
              child: SleuthFocusInkWell(
                onTap: onCopy!,
                excludeFromSemantics: true,
                borderRadius: radius,
                builder: (context, showFocus) => SleuthFocusOutline(
                  show: showFocus,
                  color: theme.checkboxActive,
                  borderRadius: radius,
                  child: SizedBox(
                    width: 48,
                    height: 48,
                    child: Icon(
                      Icons.content_copy_outlined,
                      size: 16,
                      color: theme.textSecondary,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ReconnectButton extends StatelessWidget {
  const _ReconnectButton({
    required this.busy,
    required this.onTap,
    required this.color,
  });

  final bool busy;
  final VoidCallback onTap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);
    final radius = BorderRadius.circular(theme.radiusLg);
    final label = busy ? 'Reconnecting' : 'Reconnect';
    return Semantics(
      container: true,
      button: true,
      enabled: !busy,
      label: label,
      onTap: busy ? null : onTap,
      excludeSemantics: true,
      child: SleuthFocusInkWell(
        onTap: busy ? () {} : onTap,
        excludeFromSemantics: true,
        borderRadius: radius,
        builder: (context, showFocus) => ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          child: Center(
            widthFactor: 1,
            child: SleuthFocusOutline(
              show: showFocus,
              color: theme.checkboxActive,
              borderRadius: radius,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: radius,
                  border: Border.all(color: color),
                ),
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: theme.spacingLg,
                    vertical: theme.spacingSm,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.refresh, size: 14, color: color),
                      SizedBox(width: theme.spacingXs),
                      Text(
                        busy ? 'Reconnecting…' : 'Reconnect',
                        style: TextStyle(
                          color: color,
                          fontSize: theme.fontMd,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The one debug-run banner: debug timings are slower than release, and
/// with deep instrumentation on, its counts help attribution while its
/// timings do not reflect release.
class SleuthDebugBanner extends StatelessWidget {
  const SleuthDebugBanner({
    super.key,
    required this.instrumentationActive,
    required this.onDismiss,
  });

  final bool instrumentationActive;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);
    final style = TextStyle(
      color: theme.bannerDebugText,
      fontSize: theme.fontSm,
      height: 1.4,
    );
    // Chrome, like the header and the status row: its text stops growing
    // at the chrome limit, so large text leaves room for the list.
    return SleuthTextScaleClamp(
      maxScaleFactor: kChromeMaxTextScale,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          theme.spacingMd,
          theme.spacingSm,
          theme.spacingMd,
          0,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: theme.bannerDebugBg,
            borderRadius: BorderRadius.circular(theme.radiusLg),
          ),
          child: Padding(
            padding: EdgeInsets.only(left: theme.spacingMd),
            child: Row(
              children: [
                ExcludeSemantics(
                  child: Icon(
                    Icons.warning_amber,
                    size: 14,
                    color: theme.bannerDebugText,
                  ),
                ),
                SizedBox(width: theme.spacingSm),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: theme.spacingSm),
                    child: Text.rich(
                      TextSpan(
                        children: [
                          const TextSpan(
                            text: 'Debug build. ',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                          const TextSpan(
                            text:
                                'Timings run slower than release; confirm with '
                                'flutter run --profile.',
                          ),
                          if (instrumentationActive)
                            const TextSpan(
                              text:
                                  ' Instrumentation is on, so its timings do not '
                                  'reflect release either.',
                            ),
                        ],
                      ),
                      style: style,
                    ),
                  ),
                ),
                Semantics(
                  container: true,
                  button: true,
                  label: 'Dismiss debug banner',
                  onTap: onDismiss,
                  excludeSemantics: true,
                  child: SleuthFocusInkWell(
                    onTap: onDismiss,
                    excludeFromSemantics: true,
                    borderRadius: BorderRadius.circular(theme.radiusLg),
                    builder: (context, showFocus) => SleuthFocusOutline(
                      show: showFocus,
                      color: theme.checkboxActive,
                      borderRadius: BorderRadius.circular(theme.radiusLg),
                      child: SizedBox(
                        width: 48,
                        height: 48,
                        child: Icon(
                          Icons.close,
                          size: 14,
                          color: theme.bannerDebugText,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "New to Sleuth? Open the Guide", under a status line.
class SleuthGuideLink extends StatelessWidget {
  const SleuthGuideLink({super.key, required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);
    final radius = BorderRadius.circular(theme.radiusSm);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: theme.spacingLg),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            'New to Sleuth? ',
            style: TextStyle(color: theme.textTertiary, fontSize: theme.fontMd),
          ),
          Semantics(
            container: true,
            button: true,
            label: 'Open the Guide',
            onTap: onOpen,
            excludeSemantics: true,
            child: SleuthFocusInkWell(
              onTap: onOpen,
              excludeFromSemantics: true,
              borderRadius: radius,
              builder: (context, showFocus) => ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                child: Center(
                  widthFactor: 1,
                  child: SleuthFocusOutline(
                    show: showFocus,
                    color: theme.checkboxActive,
                    borderRadius: radius,
                    child: Text(
                      'Open the Guide',
                      style: TextStyle(
                        color: theme.checkboxActive,
                        fontSize: theme.fontMd,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
