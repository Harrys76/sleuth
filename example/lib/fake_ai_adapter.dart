import 'dart:async';
import 'dart:io' show HttpException;

import 'package:sleuth/sleuth.dart';

/// Scripted reply of [FakeAiChatAdapter].
enum FakeAiMode {
  /// Streams three sentences, then ends.
  ok,

  /// Fails after 300 ms with an HTTP 503 (shown as "Provider error").
  fail,

  /// Sends one token, then nothing: the chat's stall timeout ends it.
  stall,

  /// Sends two tokens, then fails (shown as "Reply failed" with the
  /// partial text kept on screen).
  partial,

  /// Sends the first token after 8 s ("Still waiting for a reply" from
  /// 5 s), then streams like [ok].
  slow,

  /// Ends without any token (shown as "Reply failed").
  empty,
}

/// An [AiChatAdapter] that answers from a script instead of a model, for
/// checking the chat's states on a device without a provider. Selected
/// with `--dart-define=SLEUTH_AI_FAKE=ok|fail|stall|partial|slow|empty`.
class FakeAiChatAdapter extends AiChatAdapter {
  FakeAiChatAdapter(
    this.mode, {
    this.tokenInterval = const Duration(milliseconds: 120),
    this.slowFirstToken = const Duration(seconds: 8),
  }) : super(
         sendMessage: (request) =>
             _reply(mode, tokenInterval, slowFirstToken, request),
       );

  /// The adapter for a `SLEUTH_AI_FAKE` value, or null when [value]
  /// names no mode.
  static FakeAiChatAdapter? forMode(String value) {
    for (final mode in FakeAiMode.values) {
      if (mode.name == value) return FakeAiChatAdapter(mode);
    }
    return null;
  }

  final FakeAiMode mode;

  /// Delay before each token.
  final Duration tokenInterval;

  /// Delay before the first token in [FakeAiMode.slow].
  final Duration slowFirstToken;

  static Stream<String> _reply(
    FakeAiMode mode,
    Duration interval,
    Duration slowFirstToken,
    AiChatRequest request,
  ) {
    final question = request.history.isEmpty
        ? ''
        : request.history.last.text.split('\n').first;
    final tokens = switch (mode) {
      FakeAiMode.ok || FakeAiMode.slow => <String>[
        'This is a scripted reply. ',
        'You asked: "$question". ',
        'No model was called.',
      ],
      FakeAiMode.fail || FakeAiMode.empty => const <String>[],
      FakeAiMode.stall => const <String>['Starting a reply that stalls'],
      FakeAiMode.partial => const <String>['Part of a reply ', 'that breaks'],
    };
    // Time of the first token; later tokens follow every [interval].
    final first = mode == FakeAiMode.slow ? slowFirstToken : interval;

    final timers = <Timer>[];
    late final StreamController<String> controller;
    controller = StreamController<String>(
      onListen: () {
        for (var i = 0; i < tokens.length; i++) {
          timers.add(
            Timer(first + interval * i, () {
              if (!controller.isClosed) controller.add(tokens[i]);
            }),
          );
        }
        final end = first + interval * tokens.length;
        switch (mode) {
          case FakeAiMode.ok:
          case FakeAiMode.slow:
          case FakeAiMode.empty:
            timers.add(Timer(end, controller.close));
          case FakeAiMode.fail:
            timers.add(
              Timer(const Duration(milliseconds: 300), () {
                controller
                  ..addError(
                    const HttpException(
                      'AI provider returned 503: scripted failure',
                    ),
                  )
                  ..close();
              }),
            );
          case FakeAiMode.partial:
            timers.add(
              Timer(end, () {
                controller
                  ..addError(Exception('Connection closed mid-reply'))
                  ..close();
              }),
            );
          case FakeAiMode.stall:
            // Nothing more: the stream stays open until cancelled.
            break;
        }
      },
      onCancel: () {
        for (final t in timers) {
          t.cancel();
        }
      },
    );
    return controller.stream;
  }
}
