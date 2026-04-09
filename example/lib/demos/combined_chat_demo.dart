import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../demo_scaffold.dart';

// ───────────────────────────────────────────────
// Combined Demo 4: Chat App
// ───────────────────────────────────────────────
// Triggers: Rebuild, SetStateScope, KeepAlive, PlatformChannel, ImageMemory
// Interaction-dependent issues — problems that only appear during active use.

/// A messaging screen with 6 conversation tabs that stacks 5 anti-patterns:
/// a Timer.periodic calling top-level setState to deliver messages,
/// AutomaticKeepAliveClientMixin on every tab (6 > the KeepAlive threshold
/// of 5), a 40ms typing-indicator poll (25 calls/sec > the PlatformChannel
/// threshold of 20), uncached 200×200 avatars on every message, and an
/// inline text field that rebuilds the whole body on keyboard open.
class CombinedChatDemo extends StatefulWidget {
  const CombinedChatDemo({super.key});

  @override
  State<CombinedChatDemo> createState() => _CombinedChatDemoState();
}

class _CombinedChatDemoState extends State<CombinedChatDemo>
    with TickerProviderStateMixin {
  static const _tabCount = 6;
  static const _initialMessagesPerTab = 25;

  /// Cap per-tab message history. Without this the list grows
  /// unbounded — a demo left running for minutes quietly becomes a
  /// memory test instead of a rebuild/keep-alive test.
  static const _maxMessagesPerTab = 100;
  static const _channel = MethodChannel('sleuth_chat_typing_channel');

  late final TabController _tabController;

  /// Bad path — per-tab lists rebuilt via top-level setState.
  late final List<List<_ChatMessage>> _badMessages;

  /// Fixed path — per-tab ValueNotifiers so only the list rebuilds.
  late final List<ValueNotifier<List<_ChatMessage>>> _fixedMessages;

  /// Running message counter per tab, used for stable message IDs.
  late final List<int> _nextMessageId;

  Timer? _messageArrivalTimer;
  Timer? _badTypingPollTimer;

  /// Whether the demo is currently showing the fixed pattern. The
  /// `onToggle` callback keeps this in sync with DemoScaffold's internal
  /// state so the shared message timer knows which path to route to.
  bool _isFixed = false;

  /// Guards concurrent invocations of [_prewarmBadTabs] so rapid toggles
  /// don't start multiple overlapping cycle sequences.
  bool _prewarming = false;

  /// Snapshot of the global `debugProfilePlatformChannels` flag captured
  /// on entry so we can restore it on dispose. Without this, navigating
  /// into and back out of this demo silently clobbers a developer's
  /// global setting.
  bool _priorDebugProfilePlatformChannels = false;

  @override
  void initState() {
    super.initState();
    _priorDebugProfilePlatformChannels = debugProfilePlatformChannels;
    debugProfilePlatformChannels = true;

    _tabController = TabController(length: _tabCount, vsync: this);

    _badMessages = List.generate(
      _tabCount,
      (tab) =>
          List.generate(_initialMessagesPerTab, (i) => _seedMessage(tab, i)),
    );
    _fixedMessages = List.generate(
      _tabCount,
      (tab) => ValueNotifier<List<_ChatMessage>>(
        List.generate(_initialMessagesPerTab, (i) => _seedMessage(tab, i)),
      ),
    );
    _nextMessageId = List.filled(_tabCount, _initialMessagesPerTab);

    _startMessageArrivalTimer();
    _startBadTypingPoll();
    _prewarmBadTabs();
  }

  /// Briefly cycles the TabController through every tab so each
  /// `_BadChatTab` actually mounts, runs `AutomaticKeepAliveClientMixin
  /// .initState`, and dispatches its `KeepAliveNotification`. Without
  /// this, TabBarView only materializes the currently-visible page, so
  /// the KeepAlive detector would see at most 1–2 active keep-alives
  /// even though all 6 tabs opt in — far below the threshold of 5, and
  /// the anti-pattern would never surface until the user manually
  /// swiped through every conversation.
  ///
  /// We step one tab per frame so TabBarView's `_warpToAdjacentTab`
  /// actually runs for each transition (non-adjacent jumps skip
  /// intermediate pages). Setting the index directly (as opposed to
  /// `animateTo`) uses the no-duration code path, so each hop commits
  /// in a single frame.
  void _prewarmBadTabs() {
    if (_prewarming || _isFixed) return;
    _prewarming = true;
    var nextIndex = 1;
    void step() {
      if (!mounted || _isFixed) {
        _prewarming = false;
        return;
      }
      if (nextIndex < _tabCount) {
        _tabController.index = nextIndex;
        nextIndex++;
        WidgetsBinding.instance.addPostFrameCallback((_) => step());
      } else {
        _tabController.index = 0;
        _prewarming = false;
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => step());
  }

  /// Append `msg` to `list` while keeping at most `_maxMessagesPerTab`
  /// entries. Drops the oldest message when the cap is hit so the demo
  /// can run indefinitely without leaking memory.
  static List<_ChatMessage> _appendCapped(
    List<_ChatMessage> list,
    _ChatMessage msg,
  ) {
    if (list.length >= _maxMessagesPerTab) {
      return [...list.sublist(list.length - _maxMessagesPerTab + 1), msg];
    }
    return [...list, msg];
  }

  static _ChatMessage _seedMessage(int tab, int index) {
    final rng = Random(tab * 1000 + index);
    final isMe = rng.nextBool();
    final templates = [
      'Hey, how is it going?',
      'Did you see the game yesterday?',
      'Lunch at the usual spot?',
      'Yeah, sounds good!',
      'Can we reschedule?',
      'Thanks for the heads up.',
      'I\'ll be there in 5 minutes.',
      'Lol, that meme was great',
    ];
    return _ChatMessage(
      id: index,
      text: templates[index % templates.length],
      isMe: isMe,
      senderTab: tab,
    );
  }

  void _startMessageArrivalTimer() {
    _messageArrivalTimer?.cancel();
    _messageArrivalTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!mounted) return;
      final tab = _tabController.index;
      final id = _nextMessageId[tab]++;
      final msg = _ChatMessage(
        id: id,
        text: 'New message #$id in conversation ${tab + 1}',
        isMe: false,
        senderTab: tab,
      );

      if (_isFixed) {
        // ✅ Fixed: update only the ValueNotifier — no outer setState.
        final notifier = _fixedMessages[tab];
        notifier.value = _appendCapped(notifier.value, msg);
      } else {
        // ❌ Bad: top-level setState rebuilds the whole screen.
        setState(() {
          _badMessages[tab] = _appendCapped(_badMessages[tab], msg);
        });
      }
    });
  }

  void _startBadTypingPoll() {
    _badTypingPollTimer?.cancel();
    // ❌ 40ms interval → 25 calls/sec, crossing the platform channel
    //    frequency threshold of 20/sec. A 10ms headroom above the
    //    threshold is intentional — the detector counts calls on the
    //    wire, not on the wall clock, so occasional main-thread jitter
    //    from a 25/sec source won't drop us below 20/sec.
    _badTypingPollTimer = Timer.periodic(const Duration(milliseconds: 40), (
      _,
    ) async {
      if (!mounted) return;
      try {
        await _channel.invokeMethod<void>('isTyping');
      } on MissingPluginException {
        // Expected — demo has no native handler. The channel call
        // itself is what the detector measures.
      } on PlatformException {
        // Ignore transient errors during the demo.
      } catch (_) {
        // Defensive — never let an unexpected exception tear down the
        // demo. The detector is what we care about here, not error
        // handling fidelity.
      }
      // The widget can unmount across the await above. Nothing uses
      // `context` here today, but re-check so any future setState /
      // context access added by a reader is safe by construction.
      if (!mounted) return;
    });
  }

  void _stopBadTypingPoll() {
    _badTypingPollTimer?.cancel();
    _badTypingPollTimer = null;
  }

  void _handleToggle(bool isFixed) {
    _isFixed = isFixed;
    if (isFixed) {
      // ✅ Fixed: stop the bad typing-indicator polling.
      _stopBadTypingPoll();
    } else {
      _startBadTypingPoll();
      // When returning to the bad path, the previous `_BadChat`
      // subtree was unmounted by the DemoScaffold ternary and its
      // keep-alive state was lost. Cycle through the tabs again so
      // the KeepAlive detector sees all 6 active clients on the next
      // scan.
      _prewarmBadTabs();
    }
  }

  @override
  void dispose() {
    _messageArrivalTimer?.cancel();
    _messageArrivalTimer = null;
    _stopBadTypingPoll();
    _tabController.dispose();
    for (final notifier in _fixedMessages) {
      notifier.dispose();
    }
    debugProfilePlatformChannels = _priorDebugProfilePlatformChannels;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DemoScaffold(
      title: 'Chat App (Combined)',
      description:
          '❌ BAD: A Timer.periodic fires top-level setState every 2s to '
          'deliver messages, rebuilding the whole screen. All $_tabCount '
          'conversation tabs opt into AutomaticKeepAliveClientMixin '
          '(>5 threshold). A typing-indicator poll fires a '
          'MethodChannel call every 40ms (25/sec, >20 threshold). Every '
          'message avatar is a full-resolution 200×200 Image.network '
          'without cacheWidth. The text input at the bottom rebuilds '
          'the whole body when the keyboard opens.\n'
          '✅ FIX: Route new messages through per-tab ValueNotifiers so '
          'only the list rebuilds; keep-alive only the first 2 tabs; '
          'remove the polling timer (use an event-driven push instead); '
          'cacheWidth: 64 on every avatar; and extract the input into '
          'its own StatefulWidget.\n\n'
          '▶ Watch new messages arrive every 2s. In the bad path the '
          'whole tree rebuilds; in the fixed path only the list animates.',
      onToggle: _handleToggle,
      body: _BadChat(
        tabController: _tabController,
        messagesPerTab: _badMessages,
      ),
      fixedBody: _FixedChat(
        tabController: _tabController,
        messagesPerTab: _fixedMessages,
      ),
    );
  }
}

// ─── Shared data ─────────────────────────────────────────────

class _ChatMessage {
  const _ChatMessage({
    required this.id,
    required this.text,
    required this.isMe,
    required this.senderTab,
  });

  final int id;
  final String text;
  final bool isMe;
  final int senderTab;
}

// ─── Bad path ────────────────────────────────────────────────

class _BadChat extends StatelessWidget {
  const _BadChat({required this.tabController, required this.messagesPerTab});

  final TabController tabController;
  final List<List<_ChatMessage>> messagesPerTab;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TabBar(
          controller: tabController,
          isScrollable: true,
          tabs: [
            for (var i = 0; i < _CombinedChatDemoState._tabCount; i++)
              Tab(text: 'Friend ${i + 1}'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: tabController,
            children: [
              for (var i = 0; i < _CombinedChatDemoState._tabCount; i++)
                // ❌ Every tab opts into AutomaticKeepAliveClientMixin →
                //    6 keep-alive clients > 5 threshold.
                _BadChatTab(tabIndex: i, messages: messagesPerTab[i]),
            ],
          ),
        ),
        // ❌ Inline text input — keyboard open causes a full body rebuild
        //    via resizeToAvoidBottomInset.
        const _BadInputBar(),
      ],
    );
  }
}

class _BadChatTab extends StatefulWidget {
  const _BadChatTab({required this.tabIndex, required this.messages});

  final int tabIndex;
  final List<_ChatMessage> messages;

  @override
  State<_BadChatTab> createState() => _BadChatTabState();
}

class _BadChatTabState extends State<_BadChatTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true; // ❌ always keep alive

  @override
  Widget build(BuildContext context) {
    super.build(context); // required by the mixin
    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: widget.messages.length,
      itemBuilder: (_, i) {
        final msg = widget.messages[i];
        return _MessageBubble(message: msg, cached: false);
      },
    );
  }
}

class _BadInputBar extends StatelessWidget {
  const _BadInputBar();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            const Expanded(
              child: TextField(
                decoration: InputDecoration(
                  hintText: 'Message…',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(onPressed: () {}, icon: const Icon(Icons.send)),
          ],
        ),
      ),
    );
  }
}

// ─── Fixed path ──────────────────────────────────────────────

class _FixedChat extends StatelessWidget {
  const _FixedChat({required this.tabController, required this.messagesPerTab});

  final TabController tabController;
  final List<ValueNotifier<List<_ChatMessage>>> messagesPerTab;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TabBar(
          controller: tabController,
          isScrollable: true,
          tabs: [
            for (var i = 0; i < _CombinedChatDemoState._tabCount; i++)
              Tab(text: 'Friend ${i + 1}'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: tabController,
            children: [
              for (var i = 0; i < _CombinedChatDemoState._tabCount; i++)
                _FixedChatTab(
                  tabIndex: i,
                  messages: messagesPerTab[i],
                  // ✅ Only the first 2 tabs stay alive — below the
                  //    KeepAlive threshold.
                  keepAlive: i < 2,
                ),
            ],
          ),
        ),
        // ✅ Extracted input — its own StatefulWidget insulates the rest
        //    of the body from text/focus rebuilds.
        const _FixedInputBar(),
      ],
    );
  }
}

class _FixedChatTab extends StatefulWidget {
  const _FixedChatTab({
    required this.tabIndex,
    required this.messages,
    required this.keepAlive,
  });

  final int tabIndex;
  final ValueNotifier<List<_ChatMessage>> messages;
  final bool keepAlive;

  @override
  State<_FixedChatTab> createState() => _FixedChatTabState();
}

class _FixedChatTabState extends State<_FixedChatTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => widget.keepAlive;

  @override
  Widget build(BuildContext context) {
    super.build(context); // required by the mixin
    // ✅ Only the ValueListenableBuilder rebuilds when a new message
    //    arrives — the rest of the scaffold is stable.
    return ValueListenableBuilder<List<_ChatMessage>>(
      valueListenable: widget.messages,
      builder: (_, messages, _) {
        return ListView.builder(
          padding: const EdgeInsets.all(8),
          itemCount: messages.length,
          itemBuilder: (_, i) =>
              _MessageBubble(message: messages[i], cached: true),
        );
      },
    );
  }
}

class _FixedInputBar extends StatefulWidget {
  const _FixedInputBar();

  @override
  State<_FixedInputBar> createState() => _FixedInputBarState();
}

class _FixedInputBarState extends State<_FixedInputBar> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                decoration: const InputDecoration(
                  hintText: 'Message…',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: () => _controller.clear(),
              icon: const Icon(Icons.send),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Message bubble ──────────────────────────────────────────

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message, required this.cached});

  final _ChatMessage message;
  final bool cached;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final alignment = message.isMe
        ? CrossAxisAlignment.end
        : CrossAxisAlignment.start;
    final bubbleColor = message.isMe
        ? theme.colorScheme.primary
        : theme.colorScheme.surfaceContainerHighest;
    final textColor = message.isMe
        ? theme.colorScheme.onPrimary
        : theme.colorScheme.onSurface;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: message.isMe
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!message.isMe) _Avatar(message: message, cached: cached),
          if (!message.isMe) const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: alignment,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: bubbleColor,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    message.text,
                    style: TextStyle(color: textColor, fontSize: 14),
                  ),
                ),
              ],
            ),
          ),
          if (message.isMe) const SizedBox(width: 8),
          if (message.isMe) _Avatar(message: message, cached: cached),
        ],
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.message, required this.cached});

  final _ChatMessage message;
  final bool cached;

  @override
  Widget build(BuildContext context) {
    final seed = message.isMe
        ? 'me_${message.senderTab}'
        : 'friend_${message.senderTab}_${message.id}';
    return ClipOval(
      child: Image.network(
        'https://picsum.photos/seed/$seed/200/200',
        width: 32,
        height: 32,
        fit: BoxFit.cover,
        // ✅ Fixed path: cacheWidth at 2× display size (32×32 avatars →
        //    64 cache for high-DPI screens). ❌ Bad path: no cacheWidth.
        cacheWidth: cached ? 64 : null,
        cacheHeight: cached ? 64 : null,
        errorBuilder: (_, _, _) => Container(
          width: 32,
          height: 32,
          color: Colors.grey.shade300,
          child: const Icon(Icons.person, size: 18),
        ),
      ),
    );
  }
}
