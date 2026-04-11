import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/ai_chat_adapter.dart';
import '../models/performance_issue.dart';
import '../utils/ai_context_builder.dart';
import 'issue_card.dart';
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

  @override
  State<AiChatPage> createState() => _AiChatPageState();
}

class _AiChatPageState extends State<AiChatPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entranceController;
  late final CurvedAnimation _entranceCurve;
  final _inputController = TextEditingController();
  final _focusNode = FocusNode();
  final _scrollController = ScrollController();

  StreamSubscription<String>? _activeStream;
  bool _isStreaming = false;
  String _streamBuffer = '';
  late List<AiChatMessage> _messages;
  bool _showStarters = true;

  @override
  void initState() {
    super.initState();
    _messages = List.of(widget.history);
    if (_messages.isNotEmpty) _showStarters = false;
    _entranceController = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    )..forward();
    _entranceCurve = CurvedAnimation(
      parent: _entranceController,
      curve: Curves.easeOut,
    );
  }

  @override
  void dispose() {
    _activeStream?.cancel();
    _inputController.dispose();
    _focusNode.dispose();
    _scrollController.dispose();
    _entranceCurve.dispose();
    _entranceController.dispose();
    super.dispose();
  }

  void _sendMessage(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty || _isStreaming) return;

    _inputController.clear();
    setState(() {
      _showStarters = false;
      _messages.add(AiChatMessage(role: AiChatRole.user, text: trimmed));
      _isStreaming = true;
      _streamBuffer = '';
    });
    widget.onHistoryChanged(List.of(_messages));
    _scrollToBottom();

    final systemPrompt = AiContextBuilder.buildSystemPrompt(
      issue: widget.issue,
      allIssues: widget.allIssues,
    );

    final request = AiChatRequest(
      systemPrompt: systemPrompt,
      history: List.of(_messages),
    );

    _activeStream?.cancel();
    _activeStream = widget.adapter.sendMessage(request).listen(
      (token) {
        if (!mounted) return;
        setState(() => _streamBuffer += token);
        _scrollToBottom();
      },
      onDone: () {
        if (!mounted) return;
        setState(() {
          if (_streamBuffer.isNotEmpty) {
            _messages.add(AiChatMessage(
              role: AiChatRole.assistant,
              text: _streamBuffer,
            ));
          }
          _streamBuffer = '';
          _isStreaming = false;
        });
        widget.onHistoryChanged(List.of(_messages));
      },
      onError: (Object error) {
        if (!mounted) return;
        if (!kReleaseMode) {
          // ignore: avoid_print
          print('Sleuth AI error: $error');
        }
        setState(() {
          final errorText = !kReleaseMode
              ? 'Error: $error'
              : 'Something went wrong. Check your AI provider configuration.';
          _messages.add(AiChatMessage(
            role: AiChatRole.assistant,
            text: errorText,
          ));
          _streamBuffer = '';
          _isStreaming = false;
        });
        widget.onHistoryChanged(List.of(_messages));
      },
    );
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);
    final keyboardHeight = MediaQuery.viewInsetsOf(context).bottom;

    return FadeTransition(
      opacity: _entranceCurve,
      child: Container(
        color: theme.pageBackground,
        padding: EdgeInsets.only(bottom: keyboardHeight),
        child: Column(
          children: [
            _buildHeader(theme),
            _buildIssueContext(theme),
            Expanded(child: _buildMessageArea(theme)),
            _buildInputBar(theme),
          ],
        ),
      ),
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
        border: Border(
          bottom: BorderSide(color: theme.border, width: 0.5),
        ),
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
                width: 36,
                height: 36,
                child: Center(
                  child: Icon(Icons.arrow_back,
                      color: theme.textSecondary, size: 16),
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
                width: 36,
                height: 36,
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
      ..writeln('**Confidence:** ${issue.confidence.name.toUpperCase()}'
          '${issue.confidenceReason != null ? ' — ${_escapeMd(issue.confidenceReason!)}' : ''}')
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
    try {
      await Clipboard.setData(ClipboardData(text: buf.toString()));
    } catch (_) {
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text('Conversation copied to clipboard'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Widget _buildIssueContext(SleuthThemeData theme) {
    // Cap expanded card height so it can't compress the chat area to zero
    // on small screens. 40% of screen is enough for full detail + fix hint.
    final maxHeight = MediaQuery.sizeOf(context).height * 0.4;
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
        if (_isStreaming && _streamBuffer.isNotEmpty)
          _buildStreamingBubble(theme),
        if (_isStreaming && _streamBuffer.isEmpty)
          _buildThinkingIndicator(theme),
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
            runSpacing: theme.spacingXs,
            children: questions
                .map((q) => _StarterChip(
                      text: q,
                      onTap: () => _sendMessage(q),
                    ))
                .toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildAvatar({
    required SleuthThemeData theme,
    required bool isUser,
  }) {
    // DecoratedBox (NOT Container) to avoid breaking thinking-dots test
    // which counts Container widgets with BoxShape.circle.
    return SizedBox(
      width: _avatarSize,
      height: _avatarSize,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: isUser
              ? Color.alphaBlend(
                  const Color(0x33000000), theme.aiChatUserBubbleBg)
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
      child: Text(
        msg.text,
        style: TextStyle(
          color: isUser ? theme.aiChatUserBubbleText : theme.textPrimary,
          fontSize: theme.fontSm,
          height: 1.5,
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
                Flexible(
                  flex: 4,
                  child: bubble,
                ),
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
            padding: EdgeInsets.only(
              left: labelInset,
              top: theme.spacingXxs,
            ),
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
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => Clipboard.setData(ClipboardData(text: msg.text)),
                  child: SizedBox(
                    width: 36,
                    height: 24,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child:
                          Icon(Icons.copy, color: theme.textTertiary, size: 12),
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

  Widget _buildStreamingBubble(SleuthThemeData theme) {
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
                '$_streamBuffer\u258C',
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

  Widget _buildThinkingIndicator(SleuthThemeData theme) {
    return Padding(
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
        ],
      ),
    );
  }

  Widget _buildInputBar(SleuthThemeData theme) {
    return Container(
      padding: EdgeInsets.all(theme.spacingMd),
      decoration: BoxDecoration(
        color: theme.cardBackground,
        border: Border(
          top: BorderSide(color: theme.border, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _inputController,
              focusNode: _focusNode,
              enabled: !_isStreaming,
              style: TextStyle(
                color: theme.textPrimary,
                fontSize: theme.fontMd,
              ),
              decoration: InputDecoration(
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
              onSubmitted: _sendMessage,
            ),
          ),
          SizedBox(width: theme.spacingMd),
          GestureDetector(
            onTap:
                _isStreaming ? null : () => _sendMessage(_inputController.text),
            child: SizedBox(
              width: 32,
              height: 32,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: _isStreaming
                      ? theme.textQuaternary
                      : theme.aiChatUserBubbleBg,
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Icon(
                    Icons.send,
                    color: _isStreaming
                        ? theme.cardBackground
                        : theme.aiChatUserBubbleText,
                    size: 14,
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

/// Starter question pill chip with press-state visual feedback.
class _StarterChip extends StatefulWidget {
  const _StarterChip({
    required this.text,
    required this.onTap,
  });

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
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
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
    );
  }
}
