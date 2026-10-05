import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ai/ai_providers.dart';
import '../models/ai_chat_adapter.dart';
import '../models/performance_issue.dart';
import '../utils/ai_context_builder.dart';
import '../utils/ai_session_context.dart';
import 'issue_card.dart';
import 'motion.dart';
import 'sleuth_theme.dart';

/// Full-screen AI chat page for contextual conversations about a specific
/// performance issue.
///
/// Follows the [IssueEncyclopediaPage] pattern: `Positioned.fill` in the
/// [FloatingIssuesCard] Stack, toggled by a local boolean.
///
/// The page builds a rich system prompt from the issue data and encyclopedia
/// knowledge via [AiContextBuilder], then delegates to the host app's
/// [AiChatAdapter] for the actual AI API call.
class AiChatPage extends StatefulWidget {
  const AiChatPage({
    super.key,
    required this.issue,
    required this.allIssues,
    required this.adapter,
    required this.history,
    required this.onHistoryChanged,
    required this.onClose,
    this.onNotify,
    this.onNotifyAction,
    this.sessionContext,
  });

  /// The performance issue being discussed.
  final PerformanceIssue issue;

  /// All currently active issues, for cross-issue context in the prompt.
  final List<PerformanceIssue> allIssues;

  /// The AI adapter provided by the host app.
  final AiChatAdapter adapter;

  /// Prior conversation messages (persisted by FloatingIssuesCard).
  final List<AiChatMessage> history;

  /// Called when messages change so FloatingIssuesCard can persist them.
  final ValueChanged<List<AiChatMessage>> onHistoryChanged;

  /// Close this page and return to the main card.
  final VoidCallback onClose;

  /// Shows a short confirmation (copied, copy failed) in the host's
  /// toast. The page sits outside any [ScaffoldMessenger].
  final ValueChanged<String>? onNotify;

  /// Shows a notice with an action (the send-while-replying notice offers
  /// Stop). Null falls back to [onNotify] without the action.
  final void Function(
    String message,
    String actionLabel,
    VoidCallback onAction,
  )?
  onNotifyAction;

  /// The app's state for the prompt's "## Session" section, read when a
  /// message is sent and for the caption above the input. Null leaves
  /// the section out.
  final AiSessionContext Function()? sessionContext;

  @override
  State<AiChatPage> createState() => _AiChatPageState();
}

/// Short, user-facing reason for a failed reply.
///
/// HTTP 401/403 is "API key rejected", 429 "Rate limited", 5xx "Provider
/// error", a socket failure "Offline"; anything else "Reply failed". The
/// full error text is only offered through Copy error.
@visibleForTesting
String aiFailureReason(Object error) {
  final status = switch (error) {
    AiProviderException(:final statusCode) => statusCode,
    HttpException(:final message) => _statusIn(message),
    _ => _statusIn(error.toString()),
  };
  if (status == 401 || status == 403) return 'API key rejected';
  if (status == 429) return 'Rate limited';
  if (status != null && status >= 500 && status < 600) return 'Provider error';
  final text = error.toString();
  if (error is SocketException ||
      text.contains('SocketException') ||
      text.contains('Failed host lookup')) {
    return 'Offline';
  }
  return 'Reply failed';
}

final RegExp _statusPattern = RegExp(
  r'(?:returned|status(?: code)?:?)\s*(\d{3})\b',
  caseSensitive: false,
);

int? _statusIn(String text) {
  final match = _statusPattern.firstMatch(text);
  return match == null ? null : int.parse(match.group(1)!);
}

/// Where the current reply is.
enum _ReplyState { idle, waiting, streaming, done, stopped, failed }

/// A failed reply: the short [reason] shown in the failure row and the
/// full error text behind Copy error ([fullText], null when there is
/// nothing more to copy).
class _ReplyFailure {
  const _ReplyFailure(this.reason, [this.fullText]);

  final String reason;
  final String? fullText;
}

class _AiChatPageState extends State<AiChatPage>
    with SingleTickerProviderStateMixin {
  /// Longest wait for the first token of a reply.
  static const Duration _firstTokenTimeout = Duration(seconds: 30);

  /// Longest gap between two tokens of a reply.
  static const Duration _stallTimeout = Duration(seconds: 15);

  /// Wait before the thinking row reads "Still waiting for a reply".
  static const Duration _slowAfter = Duration(seconds: 5);

  /// Shortest interval between two changes of the streaming live region.
  static const Duration _announceInterval = Duration(seconds: 2);

  /// Longest message the input accepts.
  static const int _maxInputLength = 4000;

  /// Height the message list keeps when the issue context gives way.
  static const double _minMessageAreaHeight = 48;

  /// Smallest height the issue context is shown at; below it the context
  /// is left out until there is room again.
  static const double _minContextHeight = 48;

  late final AnimationController _entranceController;
  late final CurvedAnimation _entranceCurve;
  final _inputController = TextEditingController();
  final _focusNode = FocusNode();
  final _scrollController = ScrollController();

  StreamSubscription<String>? _activeStream;
  _ReplyState _state = _ReplyState.idle;

  /// Set while the last reply failed (or never finished); cleared by a
  /// send or Retry. Never written to the history.
  _ReplyFailure? _failure;

  /// Text a failed reply produced before it failed: shown above the
  /// failure row, never written to the history.
  String? _failedPartial;

  /// First-token, then stall, timeout of the reply in flight.
  Timer? _replyTimer;
  Timer? _slowTimer;
  Timer? _announceTimer;
  bool _slow = false;

  /// Label of the streaming live region, refreshed at most every
  /// [_announceInterval].
  String _streamAnnouncement = 'Reply in progress';
  bool _announcePending = false;

  /// The input had focus when the last message was sent; focus returns to
  /// it when the reply ends.
  bool _refocusAfterReply = false;
  String _streamBuffer = '';
  late List<AiChatMessage> _messages;
  bool _showStarters = true;

  /// Text of the quiet row under an unanswered question: "Stopped" after
  /// Stop, "Reply did not finish" for a question carried over from an
  /// earlier visit.
  String _stoppedNote = 'Stopped';

  /// Session context of the last request, for Copy conversation.
  AiSessionContext? _sentContext;

  /// The issue context card is expanded; kept here so the card comes
  /// back as it was after it gave way to the keyboard.
  bool _contextExpanded = false;

  bool get _inFlight =>
      _state == _ReplyState.waiting || _state == _ReplyState.streaming;

  bool get _endsWithUserTurn =>
      _messages.isNotEmpty && _messages.last.role == AiChatRole.user;

  @override
  void initState() {
    super.initState();
    _messages = List.of(widget.history);
    if (_messages.isNotEmpty) _showStarters = false;
    // A conversation left with an unanswered question (the page closed
    // while a reply failed, was stopped, or before it began) offers Retry
    // in the quiet row: the failure row is for a failure seen here.
    if (_endsWithUserTurn) {
      _state = _ReplyState.stopped;
      _stoppedNote = 'Reply did not finish';
    }
    _entranceController = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );
    _entranceCurve = CurvedAnimation(
      parent: _entranceController,
      curve: Curves.easeOut,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    startEntrance(context, _entranceController);
  }

  @override
  void dispose() {
    // Closing the page, system back, or the card pruning the chat: a
    // reply in flight keeps the text it produced.
    _finish(_ReplyState.stopped, notify: false);
    _cancelTimers();
    _inputController.dispose();
    _focusNode.dispose();
    _scrollController.dispose();
    _entranceCurve.dispose();
    _entranceController.dispose();
    super.dispose();
  }

  void _cancelTimers() {
    _replyTimer?.cancel();
    _replyTimer = null;
    _slowTimer?.cancel();
    _slowTimer = null;
    _announceTimer?.cancel();
    _announceTimer = null;
  }

  void _sendMessage(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    if (_inFlight) {
      const notice = 'Wait for the reply, or stop it';
      final withAction = widget.onNotifyAction;
      if (withAction != null) {
        withAction(notice, 'Stop', () {
          if (mounted) _stop();
        });
      } else {
        widget.onNotify?.call(notice);
      }
      return;
    }

    _inputController.clear();
    _refocusAfterReply = _focusNode.hasFocus;
    setState(() {
      _showStarters = false;
      _failure = null;
      _failedPartial = null;
      // A question after an unanswered one keeps its own bubble; the
      // request joins them ([_requestHistory]).
      _messages.add(AiChatMessage(role: AiChatRole.user, text: trimmed));
    });
    widget.onHistoryChanged(List.of(_messages));
    _startReply();
  }

  /// Asks again for a reply to the unanswered question that ends the
  /// history, without adding a turn.
  void _retry() {
    if (_inFlight || !_endsWithUserTurn) return;
    _refocusAfterReply = true;
    setState(() {
      _failure = null;
      _failedPartial = null;
    });
    _startReply();
  }

  void _stop() {
    if (!_inFlight) return;
    _haptic();
    _finish(_ReplyState.stopped);
  }

  void _onRetryTap() {
    _haptic();
    _retry();
  }

  static void _haptic() =>
      unawaited(HapticFeedback.selectionClick().catchError((Object _) {}));

  /// Cancels the reply subscription. An adapter whose cancel fails does
  /// not reach the app's zone.
  void _cancelStream() {
    final sub = _activeStream;
    _activeStream = null;
    if (sub != null) unawaited(sub.cancel().catchError((Object _) {}));
  }

  /// The history as sent: consecutive user turns (a question asked after
  /// an unanswered one) joined into one, a blank line between, so no
  /// provider gets two user turns in a row.
  List<AiChatMessage> _requestHistory() {
    final out = <AiChatMessage>[];
    for (final message in _messages) {
      if (message.role == AiChatRole.user &&
          out.isNotEmpty &&
          out.last.role == AiChatRole.user) {
        final previous = out.removeLast();
        out.add(
          AiChatMessage(
            role: AiChatRole.user,
            text: '${previous.text}\n\n${message.text}',
          ),
        );
      } else {
        out.add(message);
      }
    }
    return out;
  }

  /// Requests a reply to the history as it stands.
  void _startReply() {
    final session = widget.sessionContext?.call();
    _sentContext = session ?? _sentContext;
    final systemPrompt = AiContextBuilder.buildSystemPrompt(
      issue: widget.issue,
      allIssues: widget.allIssues,
      session: session,
    );
    final request = AiChatRequest(
      systemPrompt: systemPrompt,
      history: _requestHistory(),
    );

    _cancelStream();
    _cancelTimers();
    setState(() {
      _state = _ReplyState.waiting;
      _streamBuffer = '';
      _slow = false;
      _announcePending = false;
      _streamAnnouncement = 'Reply in progress';
    });
    _armReplyTimer(_firstTokenTimeout, 'No reply in 30 s');
    _slowTimer = Timer(_slowAfter, () {
      if (mounted && _state == _ReplyState.waiting) {
        setState(() => _slow = true);
      }
    });
    _scrollToBottom();

    final Stream<String> stream;
    try {
      stream = widget.adapter.sendMessage(request);
    } catch (e) {
      _onReplyError(e);
      return;
    }
    _activeStream = stream.listen(
      _onToken,
      onError: _onReplyError,
      onDone: () => _finish(_ReplyState.done),
      cancelOnError: true,
    );
  }

  void _armReplyTimer(Duration timeout, String reason) {
    _replyTimer?.cancel();
    _replyTimer = Timer(timeout, () {
      _finish(
        _ReplyState.failed,
        failure: _ReplyFailure(
          reason,
          'No reply text arrived within ${timeout.inSeconds} s.',
        ),
      );
    });
  }

  void _onToken(String token) {
    if (!mounted || !_inFlight || token.isEmpty) return;
    _armReplyTimer(_stallTimeout, 'Reply stalled');
    _slowTimer?.cancel();
    _slowTimer = null;
    setState(() {
      _state = _ReplyState.streaming;
      _streamBuffer += token;
      _slow = false;
    });
    _scheduleAnnouncement();
    _scrollToBottom();
  }

  void _onReplyError(Object error) {
    if (!kReleaseMode) debugPrint('Sleuth AI error: $error');
    _finish(
      _ReplyState.failed,
      failure: _ReplyFailure(aiFailureReason(error), '$error'),
    );
  }

  /// Updates the streaming live region now, or once the current
  /// [_announceInterval] has passed, so a screen reader hears progress
  /// rather than every token.
  void _scheduleAnnouncement() {
    if (_announceTimer != null) {
      _announcePending = true;
      return;
    }
    _announce();
    _announceTimer = Timer(_announceInterval, _onAnnounceTick);
  }

  void _onAnnounceTick() {
    _announceTimer = null;
    if (!mounted || _state != _ReplyState.streaming || !_announcePending) {
      return;
    }
    _announcePending = false;
    setState(_announce);
    _announceTimer = Timer(_announceInterval, _onAnnounceTick);
  }

  void _announce() {
    final sentences = _sentenceEnd.allMatches(_streamBuffer).length;
    _streamAnnouncement = sentences == 0
        ? 'Reply in progress'
        : 'Reply in progress, $sentences '
              '${sentences == 1 ? 'sentence' : 'sentences'}';
  }

  static final RegExp _sentenceEnd = RegExp(r'[.!?](\s|$)');

  /// Ends the reply in flight once; later calls do nothing.
  ///
  /// [_ReplyState.done] commits the reply. [_ReplyState.stopped] commits
  /// the text received so far, marked " (stopped)", and records no
  /// failure. [_ReplyState.failed] records [failure] and keeps the text
  /// received so far on screen only. [notify] is false from [dispose]:
  /// the history callback still runs, nothing else does.
  void _finish(_ReplyState end, {_ReplyFailure? failure, bool notify = true}) {
    if (!_inFlight) return;
    _cancelStream();
    _cancelTimers();
    final partial = _streamBuffer;
    _streamBuffer = '';
    var historyChanged = false;
    var next = end;
    switch (end) {
      case _ReplyState.done:
        if (partial.isEmpty) {
          next = _ReplyState.failed;
          _failure = const _ReplyFailure(
            'Reply failed',
            'The provider ended the reply without any text.',
          );
        } else {
          _messages.add(
            AiChatMessage(role: AiChatRole.assistant, text: partial),
          );
          historyChanged = true;
        }
      case _ReplyState.stopped:
        _stoppedNote = 'Stopped';
        if (partial.isNotEmpty) {
          _messages.add(
            AiChatMessage(
              role: AiChatRole.assistant,
              text: '$partial (stopped)',
            ),
          );
          historyChanged = true;
        }
      case _ReplyState.failed:
        _failure = failure ?? const _ReplyFailure('Reply failed');
        _failedPartial = partial.isEmpty ? null : partial;
      case _ReplyState.idle:
      case _ReplyState.waiting:
      case _ReplyState.streaming:
        break;
    }
    _state = next;
    if (historyChanged) widget.onHistoryChanged(List.of(_messages));
    if (!notify || !mounted) return;
    setState(() {});
    _restoreFocus();
  }

  /// Puts focus back on the input after a reply when it had focus at send
  /// (always after Retry).
  void _restoreFocus() {
    if (_refocusAfterReply && !_focusNode.hasFocus) _focusNode.requestFocus();
    _refocusAfterReply = false;
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_scrollController.hasClients) {
        final end = _scrollController.position.maxScrollExtent;
        if (reducedMotionOf(context)) {
          _scrollController.jumpTo(end);
        } else {
          _scrollController.animateTo(
            end,
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
          );
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);
    final keyboardHeight = MediaQuery.viewInsetsOf(context).bottom;
    // 40 % of the screen is enough for the full detail and fix hint.
    final contextCap = MediaQuery.sizeOf(context).height * 0.4;
    final header = _buildHeader(theme);
    final messages = _buildMessageArea(theme);
    final inputBar = _buildInputBar(theme);

    // A Material surface: the TextField needs a Material ancestor, and ink
    // and text selection paint on it. The page is a sibling of the card's
    // Material, not a descendant.
    //
    // The input bar keeps its full height above the keyboard. The space
    // above it goes to the header, then to a minimum message area, and
    // the issue context takes what is left (up to its cap), so the
    // context gives way first when the keyboard or large text leaves
    // little room.
    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      label: 'Ask AI',
      child: FadeTransition(
        opacity: _entranceCurve,
        child: Material(
          color: theme.pageBackground,
          child: Padding(
            padding: EdgeInsets.only(bottom: keyboardHeight),
            child: LayoutBuilder(
              builder: (context, page) => Column(
                children: [
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, above) => _buildAboveInput(
                        theme,
                        height: above.maxHeight,
                        header: header,
                        contextCap: contextCap,
                        messages: messages,
                      ),
                    ),
                  ),
                  // On a page shorter than the bar (large text, a landscape
                  // phone with the keyboard up) the bar scrolls, held at its
                  // bottom: the field and Send stay in view and the session
                  // caption gives way.
                  ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: page.maxHeight),
                    child: SingleChildScrollView(
                      reverse: true,
                      primary: false,
                      child: inputBar,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The header over the issue context and [messages], in the [height]
  /// above the input bar. The header is squeezed only when nothing else
  /// fits.
  Widget _buildAboveInput(
    SleuthThemeData theme, {
    required double height,
    required Widget header,
    required double contextCap,
    required Widget messages,
  }) {
    return Column(
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: height),
          child: header,
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) => _buildContextAndMessages(
              theme,
              height: constraints.maxHeight,
              contextCap: contextCap,
              messages: messages,
            ),
          ),
        ),
      ],
    );
  }

  /// The issue context over [messages] in [height]: the context is capped
  /// at [contextCap] and leaves the message list at least
  /// [_minMessageAreaHeight]; with less than [_minContextHeight] for it,
  /// the context is left out.
  Widget _buildContextAndMessages(
    SleuthThemeData theme, {
    required double height,
    required double contextCap,
    required Widget messages,
  }) {
    final contextHeight = math.min(
      contextCap,
      height - theme.spacingLg - _minMessageAreaHeight,
    );
    return Column(
      children: [
        if (contextHeight >= _minContextHeight)
          _buildIssueContext(theme, contextHeight),
        Expanded(child: messages),
      ],
    );
  }

  Widget _buildHeader(SleuthThemeData theme) {
    final statusBarHeight = MediaQuery.paddingOf(context).top;
    return Container(
      padding: EdgeInsets.only(
        left: theme.spacingMd,
        right: theme.spacingMd,
        bottom: theme.spacingMd,
        top: theme.spacingMd + statusBarHeight,
      ),
      decoration: BoxDecoration(
        color: theme.cardBackground,
        border: Border(bottom: BorderSide(color: theme.border, width: 0.5)),
      ),
      child: Row(
        children: [
          Semantics(
            label: 'Close AI chat',
            button: true,
            child: GestureDetector(
              onTap: widget.onClose,
              behavior: HitTestBehavior.opaque,
              child: SizedBox(
                width: 48,
                height: 48,
                child: Center(
                  child: Icon(
                    Icons.arrow_back,
                    color: theme.textSecondary,
                    size: 16,
                  ),
                ),
              ),
            ),
          ),
          SizedBox(width: theme.spacingSm),
          Icon(Icons.auto_awesome, color: theme.textTertiary, size: 14),
          SizedBox(width: theme.spacingXs),
          Expanded(
            child: Text(
              'Ask AI',
              style: TextStyle(
                color: theme.textPrimary,
                fontSize: theme.fontLg,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Semantics(
            label: 'Copy conversation',
            button: true,
            enabled: _messages.isNotEmpty,
            child: GestureDetector(
              onTap: _messages.isEmpty ? null : _copyConversation,
              behavior: HitTestBehavior.opaque,
              child: SizedBox(
                width: 48,
                height: 48,
                child: Center(
                  child: Icon(
                    Icons.copy_all_outlined,
                    color: _messages.isEmpty
                        ? theme.textQuaternary
                        : theme.textSecondary,
                    size: 16,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Escape markdown-significant characters so user/AI text doesn't break the
  /// copied markdown structure.
  static String _escapeMd(String s) => s
      .replaceAll(r'\', r'\\')
      .replaceAll('*', r'\*')
      .replaceAll('`', r'\`')
      .replaceAll('#', r'\#')
      .replaceAll('[', r'\[')
      .replaceAll(']', r'\]')
      .replaceAll('<', r'\<')
      .replaceAll('>', r'\>')
      .replaceAll('|', r'\|');

  Future<void> _copyConversation() async {
    if (_messages.isEmpty) return;
    final issue = widget.issue;
    final buf = StringBuffer()
      ..writeln('# Sleuth AI Conversation')
      ..writeln();
    buf
      ..writeln('**Issue:** ${_escapeMd(issue.title)}')
      ..writeln('**Stable ID:** `${issue.stableId ?? '-'}`')
      ..writeln(
        '**Confidence:** ${issue.confidence.name.toUpperCase()}'
        '${issue.confidenceReason != null ? ' — ${_escapeMd(issue.confidenceReason!)}' : ''}',
      )
      ..writeln()
      ..writeln('---')
      ..writeln();
    for (final msg in _messages) {
      final marker = msg.role == AiChatRole.user
          ? '### \u{1F9D1} User'
          : '### \u{1F916} Assistant';
      buf
        ..writeln(marker)
        ..writeln(_escapeMd(msg.text.trim()))
        ..writeln();
    }
    final session = _sentContext;
    if (session != null) {
      buf
        ..writeln('---')
        ..writeln()
        ..writeln('## Context sent')
        ..writeln();
      for (final line in session.render().trim().split('\n')) {
        buf.writeln('- ${_escapeMd(line)}');
      }
    }
    await _copy(buf.toString(), 'Conversation copied to clipboard');
  }

  /// Copies [text] and reports [confirmation], or a failure, through
  /// [AiChatPage.onNotify].
  Future<void> _copy(String text, String confirmation) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
    } catch (e) {
      debugPrint('Sleuth: copy failed: $e');
      if (mounted) widget.onNotify?.call("Couldn't copy");
      return;
    }
    if (mounted) widget.onNotify?.call(confirmation);
  }

  /// The issue card, scrolling inside [maxHeight].
  Widget _buildIssueContext(SleuthThemeData theme, double maxHeight) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        theme.spacingMd,
        theme.spacingLg,
        theme.spacingMd,
        0,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SingleChildScrollView(
          child: IssueCard(
            issue: widget.issue,
            // Start collapsed — tap to expand full detail, fix hint, etc.
            // "Ask AI" and "Learn more" hidden since we're already in AI chat.
            initiallyExpanded: _contextExpanded,
            onExpandedChanged: (expanded) => _contextExpanded = expanded,
          ),
        ),
      ),
    );
  }

  Widget _buildMessageArea(SleuthThemeData theme) {
    return ListView(
      controller: _scrollController,
      padding: EdgeInsets.symmetric(
        horizontal: theme.spacingLg,
        vertical: theme.spacingSm,
      ),
      children: [
        if (_showStarters) _buildStarterQuestions(theme),
        for (final msg in _messages) _buildMessageBubble(msg, theme),
        if (_state == _ReplyState.streaming) _buildStreamingBubble(theme),
        if (_state == _ReplyState.waiting) _buildThinkingIndicator(theme),
        if (_state == _ReplyState.failed && _failedPartial != null)
          _buildPartialBubble(_failedPartial!, theme),
        if (_state == _ReplyState.failed && _failure != null)
          _buildFailureRow(_failure!, theme),
        if (_state == _ReplyState.stopped && _endsWithUserTurn)
          _buildStoppedRow(theme),
      ],
    );
  }

  Widget _buildStarterQuestions(SleuthThemeData theme) {
    final questions = AiContextBuilder.starterQuestions(widget.issue);

    return Padding(
      padding: EdgeInsets.only(bottom: theme.spacingMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.only(bottom: theme.spacingSm),
            child: Text(
              'Suggested questions',
              style: TextStyle(
                color: theme.textTertiary,
                fontSize: theme.fontXs,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Wrap(
            spacing: theme.spacingXs,
            children: questions
                .map((q) => _StarterChip(text: q, onTap: () => _sendMessage(q)))
                .toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildAvatar({required SleuthThemeData theme, required bool isUser}) {
    // DecoratedBox (NOT Container) to avoid breaking thinking-dots test
    // which counts Container widgets with BoxShape.circle.
    return SizedBox(
      width: _avatarSize,
      height: _avatarSize,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: isUser
              ? Color.alphaBlend(
                  const Color(0x33000000),
                  theme.aiChatUserBubbleBg,
                )
              : theme.textQuaternary,
          shape: BoxShape.circle,
        ),
        child: Center(
          child: isUser
              ? Text(
                  'U',
                  style: TextStyle(
                    color: theme.aiChatUserBubbleText,
                    fontSize: theme.fontXs,
                    fontWeight: FontWeight.w700,
                  ),
                )
              : Icon(
                  Icons.auto_awesome,
                  color: theme.aiChatUserBubbleText,
                  size: 10,
                ),
        ),
      ),
    );
  }

  static const double _avatarSize = 20;

  Widget _buildMessageBubble(AiChatMessage msg, SleuthThemeData theme) {
    final isUser = msg.role == AiChatRole.user;
    final labelInset = _avatarSize + theme.spacingMd;

    // Asymmetric radius: small corner nearest the avatar (speech-bubble tail).
    final bubbleRadius = isUser
        ? const BorderRadius.only(
            topLeft: Radius.circular(12),
            topRight: Radius.circular(4),
            bottomLeft: Radius.circular(12),
            bottomRight: Radius.circular(12),
          )
        : const BorderRadius.only(
            topLeft: Radius.circular(4),
            topRight: Radius.circular(12),
            bottomLeft: Radius.circular(12),
            bottomRight: Radius.circular(12),
          );

    final bubble = Container(
      padding: EdgeInsets.all(theme.spacingLg),
      decoration: BoxDecoration(
        color: isUser ? theme.aiChatUserBubbleBg : theme.sectionBackground,
        borderRadius: bubbleRadius,
      ),
      // The latest reply is read out when it lands.
      child: Semantics(
        container: true,
        liveRegion: !isUser && identical(msg, _messages.last),
        child: Text(
          msg.text,
          style: TextStyle(
            color: isUser ? theme.aiChatUserBubbleText : theme.textPrimary,
            fontSize: theme.fontSm,
            height: 1.5,
          ),
        ),
      ),
    );

    if (isUser) {
      return Padding(
        padding: EdgeInsets.only(bottom: theme.spacingMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Spacer(flex: 1),
                Flexible(flex: 4, child: bubble),
                SizedBox(width: theme.spacingMd),
                _buildAvatar(theme: theme, isUser: true),
              ],
            ),
            Padding(
              padding: EdgeInsets.only(
                right: labelInset,
                top: theme.spacingXxs,
              ),
              child: Text(
                'You',
                style: TextStyle(
                  color: theme.textQuaternary,
                  fontSize: theme.fontXxs,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.only(bottom: theme.spacingMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildAvatar(theme: theme, isUser: false),
              SizedBox(width: theme.spacingMd),
              Expanded(child: bubble),
            ],
          ),
          Padding(
            padding: EdgeInsets.only(left: labelInset, top: theme.spacingXxs),
            child: Row(
              children: [
                Text(
                  'AI',
                  style: TextStyle(
                    color: theme.textQuaternary,
                    fontSize: theme.fontXxs,
                  ),
                ),
                SizedBox(width: theme.spacingMd),
                Semantics(
                  label: 'Copy message',
                  button: true,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _copy(msg.text, 'Copied'),
                    child: SizedBox(
                      width: 48,
                      height: 48,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Icon(
                          Icons.copy,
                          color: theme.textTertiary,
                          size: 12,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The reply as it streams. Its tokens are not read out one by one: the
  /// node is a live region labelled with a progress summary that changes
  /// at most every [_announceInterval]; the finished reply is read when
  /// it lands.
  Widget _buildStreamingBubble(SleuthThemeData theme) {
    return Semantics(
      container: true,
      liveRegion: true,
      label: _streamAnnouncement,
      excludeSemantics: true,
      child: _replyBubble('$_streamBuffer\u258C', theme),
    );
  }

  /// Text a failed reply produced before it failed. Shown, not kept.
  Widget _buildPartialBubble(String text, SleuthThemeData theme) =>
      Semantics(container: true, child: _replyBubble(text, theme));

  Widget _replyBubble(String text, SleuthThemeData theme) {
    return Padding(
      padding: EdgeInsets.only(bottom: theme.spacingMd),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildAvatar(theme: theme, isUser: false),
          SizedBox(width: theme.spacingMd),
          Expanded(
            child: Container(
              padding: EdgeInsets.all(theme.spacingLg),
              decoration: BoxDecoration(
                color: theme.sectionBackground,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(4),
                  topRight: Radius.circular(12),
                  bottomLeft: Radius.circular(12),
                  bottomRight: Radius.circular(12),
                ),
              ),
              child: Text(
                text,
                style: TextStyle(
                  color: theme.textPrimary,
                  fontSize: theme.fontSm,
                  height: 1.5,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Why the last reply failed, on its own line, with Retry when the
  /// history ends with an unanswered question and Copy error when there
  /// is error text, wrapped below it.
  Widget _buildFailureRow(_ReplyFailure failure, SleuthThemeData theme) {
    final canRetry = _endsWithUserTurn;
    final fullText = failure.fullText;
    final inset = theme.spacingLg - theme.spacingSm;
    return Padding(
      padding: EdgeInsets.only(bottom: theme.spacingMd),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.bannerWarningBg,
          borderRadius: BorderRadius.circular(theme.radiusXxl),
        ),
        child: Padding(
          padding: EdgeInsets.all(theme.spacingSm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: inset,
                  vertical: theme.spacingSm,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.error_outline,
                      color: theme.bannerWarningText,
                      size: 14,
                    ),
                    SizedBox(width: theme.spacingSm),
                    Expanded(
                      child: Semantics(
                        container: true,
                        liveRegion: true,
                        child: Text(
                          failure.reason,
                          style: TextStyle(
                            color: theme.bannerWarningText,
                            fontSize: theme.fontSm,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (fullText != null || canRetry)
                Wrap(
                  alignment: WrapAlignment.end,
                  children: [
                    if (fullText != null)
                      _ChatTextAction(
                        label: 'Copy error',
                        color: theme.bannerWarningText,
                        onTap: () => _copy(fullText, 'Error copied'),
                      ),
                    if (canRetry)
                      _ChatTextAction(
                        label: 'Retry',
                        color: theme.bannerWarningText,
                        onTap: _onRetryTap,
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// A reply stopped before any text arrived: a quiet note with Retry.
  Widget _buildStoppedRow(SleuthThemeData theme) {
    return Padding(
      padding: EdgeInsets.only(bottom: theme.spacingMd),
      child: Row(
        children: [
          SizedBox(width: _avatarSize + theme.spacingMd),
          Expanded(
            child: Text(
              _stoppedNote,
              style: TextStyle(
                color: theme.textTertiary,
                fontSize: theme.fontXs,
              ),
            ),
          ),
          _ChatTextAction(
            label: 'Retry',
            color: theme.textSecondary,
            onTap: _onRetryTap,
          ),
        ],
      ),
    );
  }

  Widget _buildThinkingIndicator(SleuthThemeData theme) {
    const slowLabel = 'Still waiting for a reply';
    return Semantics(
      container: true,
      liveRegion: true,
      label: _slow ? slowLabel : 'Thinking',
      excludeSemantics: true,
      child: Padding(
        padding: EdgeInsets.only(bottom: theme.spacingMd),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _buildAvatar(theme: theme, isUser: false),
            SizedBox(width: theme.spacingMd),
            for (var i = 0; i < 3; i++) ...[
              if (i > 0) SizedBox(width: theme.spacingXs),
              Container(
                width: 5,
                height: 5,
                decoration: BoxDecoration(
                  color: theme.textTertiary.withValues(alpha: 0.5),
                  shape: BoxShape.circle,
                ),
              ),
            ],
            if (_slow) ...[
              SizedBox(width: theme.spacingMd),
              Flexible(
                child: Text(
                  slowLabel,
                  style: TextStyle(
                    color: theme.textTertiary,
                    fontSize: theme.fontXs,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// What the next message carries besides the conversation, at most
  /// two lines.
  Widget _buildContextCaption(AiSessionContext session, SleuthThemeData theme) {
    return Semantics(
      container: true,
      child: Padding(
        padding: EdgeInsets.only(
          left: theme.spacingLg,
          right: theme.spacingLg,
          bottom: theme.spacingXs,
        ),
        child: Text(
          session.caption(),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: theme.textTertiary, fontSize: theme.fontXs),
        ),
      ),
    );
  }

  Widget _buildInputBar(SleuthThemeData theme) {
    final session = widget.sessionContext?.call();
    return Container(
      padding: EdgeInsets.all(theme.spacingMd),
      decoration: BoxDecoration(
        color: theme.cardBackground,
        border: Border(top: BorderSide(color: theme.border, width: 0.5)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (session != null) _buildContextCaption(session, theme),
          _buildInputRow(theme),
        ],
      ),
    );
  }

  Widget _buildInputRow(SleuthThemeData theme) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _inputController,
            focusNode: _focusNode,
            // Editable while a reply streams, so the next question can
            // be drafted; sending it waits for the reply.
            maxLength: _maxInputLength,
            buildCounter: _buildCounter,
            style: TextStyle(color: theme.textPrimary, fontSize: theme.fontMd),
            decoration: InputDecoration(
              // 48 px tall tap target.
              constraints: const BoxConstraints(minHeight: 48),
              hintText: 'Ask about this issue...',
              hintStyle: TextStyle(
                color: theme.textTertiary,
                fontSize: theme.fontMd,
              ),
              isDense: true,
              contentPadding: EdgeInsets.symmetric(
                horizontal: theme.spacingLg,
                vertical: theme.spacingSm,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(theme.radiusFull),
                borderSide: BorderSide(color: theme.border, width: 0.5),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(theme.radiusFull),
                borderSide: BorderSide(color: theme.border, width: 0.5),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(theme.radiusFull),
                borderSide: BorderSide(color: theme.textTertiary, width: 1),
              ),
              filled: true,
              fillColor: theme.sectionBackground,
            ),
            // Submitting keeps focus for the next question.
            onEditingComplete: () {},
            onSubmitted: _sendMessage,
          ),
        ),
        SizedBox(width: theme.spacingMd),
        _inFlight ? _buildStopButton(theme) : _buildSendButton(theme),
      ],
    );
  }

  /// Length counter, shown once the input passes 80 % of its limit.
  Widget? _buildCounter(
    BuildContext context, {
    required int currentLength,
    required int? maxLength,
    required bool isFocused,
  }) {
    if (maxLength == null || currentLength * 5 < maxLength * 4) return null;
    final theme = SleuthTheme.of(context);
    return Text(
      '$currentLength / $maxLength',
      style: TextStyle(color: theme.textTertiary, fontSize: theme.fontXs),
    );
  }

  Widget _buildSendButton(SleuthThemeData theme) {
    return Semantics(
      label: 'Send',
      button: true,
      child: GestureDetector(
        onTap: () => _sendMessage(_inputController.text),
        behavior: HitTestBehavior.opaque,
        child: _roundButton(
          icon: Icons.send,
          fill: theme.aiChatUserBubbleBg,
          iconColor: theme.aiChatUserBubbleText,
        ),
      ),
    );
  }

  Widget _buildStopButton(SleuthThemeData theme) {
    return Semantics(
      label: 'Stop reply',
      button: true,
      child: GestureDetector(
        onTap: _stop,
        behavior: HitTestBehavior.opaque,
        child: _roundButton(
          icon: Icons.stop,
          fill: theme.textSecondary,
          iconColor: theme.cardBackground,
        ),
      ),
    );
  }

  /// 48 x 48 hit box around a 32 px round button.
  static Widget _roundButton({
    required IconData icon,
    required Color fill,
    required Color iconColor,
  }) {
    return SizedBox(
      width: 48,
      height: 48,
      child: Center(
        child: SizedBox(
          width: 32,
          height: 32,
          child: DecoratedBox(
            decoration: BoxDecoration(color: fill, shape: BoxShape.circle),
            child: Center(child: Icon(icon, color: iconColor, size: 14)),
          ),
        ),
      ),
    );
  }
}

/// A text button in a chat row with a 48 x 48 minimum hit box, styled
/// like the toast action.
class _ChatTextAction extends StatelessWidget {
  const _ChatTextAction({
    required this.label,
    required this.color,
    required this.onTap,
  });

  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);
    return Semantics(
      label: label,
      button: true,
      onTap: onTap,
      container: true,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: theme.spacingSm),
            child: Center(
              widthFactor: 1,
              child: Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: theme.fontSm,
                  fontWeight: FontWeight.bold,
                  decoration: TextDecoration.underline,
                  decorationColor: color,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Starter question pill chip with press-state visual feedback.
class _StarterChip extends StatefulWidget {
  const _StarterChip({required this.text, required this.onTap});

  final String text;
  final VoidCallback onTap;

  @override
  State<_StarterChip> createState() => _StarterChipState();
}

class _StarterChipState extends State<_StarterChip> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);
    // 48 px tall hit box around the pill.
    return Semantics(
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Align(
            widthFactor: 1,
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: theme.spacingLg,
                vertical: theme.spacingSm,
              ),
              decoration: BoxDecoration(
                color: _pressed ? theme.border : theme.sectionBackground,
                borderRadius: BorderRadius.circular(theme.radiusFull),
                border: Border.all(color: theme.border, width: 0.5),
              ),
              child: Text(
                widget.text,
                style: TextStyle(
                  color: theme.textSecondary,
                  fontSize: theme.fontSm,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
