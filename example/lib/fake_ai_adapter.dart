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
}

/// An [AiChatAdapter] that answers from a script instead of a model, for
/// checking the chat's states on a device without a provider. Selected
/// with `--dart-define=SLEUTH_AI_FAKE=ok|fail|stall|partial`.
class FakeAiChatAdapter extends AiChatAdapter {
  FakeAiChatAdapter(
    this.mode, {
    this.tokenInterval = const Duration(milliseconds: 120),
  }) : super(sendMessage: (request) => _reply(mode, tokenInterval, request));

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

  static Stream<String> _reply(
    FakeAiMode mode,
    Duration interval,
    AiChatRequest request,
  ) {
    final question = request.history.isEmpty
        ? ''
        : request.history.last.text.split('\n').first;
    final tokens = switch (mode) {
      FakeAiMode.ok => <String>[
        'This is a scripted reply. ',
        'You asked: "$question". ',
        'No model was called.',
      ],
      FakeAiMode.fail => const <String>[],
      FakeAiMode.stall => const <String>['Starting a reply that stalls'],
      FakeAiMode.partial => const <String>['Part of a reply ', 'that breaks'],
    };

    final timers = <Timer>[];
    late final StreamController<String> controller;
    controller = StreamController<String>(
      onListen: () {
        for (var i = 0; i < tokens.length; i++) {
          timers.add(
            Timer(interval * (i + 1), () {
              if (!controller.isClosed) controller.add(tokens[i]);
            }),
          );
        }
        final end = interval * (tokens.length + 1);
        switch (mode) {
          case FakeAiMode.ok:
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
